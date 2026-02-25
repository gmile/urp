defmodule URP.Bridge do
  @moduledoc """
  Mid-level UNO operations over a URP connection.

  Manages a TCP connection to a `soffice` process and provides functions for
  the UNO operations needed for document conversion: loading documents,
  storing to URL, and closing.

  Each connection performs a handshake and bootstraps a Desktop reference
  on `open!/2`. A connection handles one conversion at a time (soffice is
  single-threaded). Close the connection with `close!/1` when done.

  ## Example

      conn = URP.Bridge.open!("localhost", 2002)
      doc = URP.Bridge.load_document!(conn, "file:///tmp/input.docx")
      URP.Bridge.store_to_url!(conn, doc, "file:///tmp/output.pdf")
      URP.Bridge.close_document!(conn, doc)
      URP.Bridge.close!(conn)

  ## Streaming

  `load_document_stream!/2` and `store_to_stream!/3` use UNO's
  `XInputStream`/`XOutputStream` interfaces to transfer document bytes
  over the URP socket, eliminating the need for a shared filesystem.

      conn = URP.Bridge.open!("localhost", 2002)
      doc = URP.Bridge.load_document_stream!(conn, File.read!("input.docx"))
      pdf = URP.Bridge.store_to_stream!(conn, doc)
      URP.Bridge.close_document!(conn, doc)
      URP.Bridge.close!(conn)
  """

  alias URP.Protocol, as: P

  defstruct [:sock, :desktop_oid]

  # UNO interface names
  @xi_protocol_props "com.sun.star.bridge.XProtocolProperties"
  @xi_interface "com.sun.star.uno.XInterface"
  @xi_component_ctx "com.sun.star.uno.XComponentContext"
  @xi_multi_comp_fac "com.sun.star.lang.XMultiComponentFactory"
  @xi_component_loader "com.sun.star.frame.XComponentLoader"
  @xi_storable2 "com.sun.star.frame.XStorable2"
  @xi_closeable "com.sun.star.util.XCloseable"
  @xi_input_stream "com.sun.star.io.XInputStream"
  @xi_output_stream "com.sun.star.io.XOutputStream"

  # Special function IDs — binaryurp/source/specialfunctionids.hxx
  @func_query_interface 0
  @func_request_change 4

  import Bitwise

  # UNO TypeClass values for property encoding — include/typelib/typeclass.h
  @tc_boolean 2
  @tc_string 12
  @tc_interface 22
  @tc_new 0x80

  # Minimum signed int32 — guarantees we lose the nonce negotiation
  @losing_nonce <<-2_147_483_648::32-signed>>

  @doc "Connect to soffice, perform URP handshake, and bootstrap a Desktop reference."
  def open!(host \\ "localhost", port \\ 2002) do
    {:ok, sock} = :gen_tcp.connect(String.to_charlist(host), port, [:binary, active: false])
    conn = %__MODULE__{sock: sock}
    handshake!(conn)
    desktop_oid = bootstrap_desktop!(conn)
    %{conn | desktop_oid: desktop_oid}
  end

  @doc "Close the TCP connection."
  def close!(%__MODULE__{sock: sock}) do
    :gen_tcp.close(sock)
  end

  @doc """
  Load a document from a `file://` URL. Returns the document OID.

  Raises if soffice cannot open the file.
  """
  def load_document!(%__MODULE__{} = conn, url) do
    qi!(
      conn,
      P.request(@func_query_interface,
        type: {:cached, 1},
        oid: {conn.desktop_oid, 4}
      ),
      P.type_new(@xi_component_loader, 5)
    )

    # loadComponentFromURL(url, "_blank", 0, [Hidden=true])
    # funcID 3 on XComponentLoader
    P.send_frame(
      conn.sock,
      P.request(3, type: {:new, @xi_component_loader, 6}) <>
        P.null_ctx() <>
        P.enc_str(url) <>
        P.enc_str("_blank") <>
        <<0::32>> <>
        <<1>> <>
        P.property("Hidden", @tc_boolean, <<1>>)
    )

    case P.parse_interface_reply(recv_reply!(conn.sock)) do
      nil ->
        raise "loadComponentFromURL returned null — file may not exist or be readable by soffice"

      oid ->
        oid
    end
  end

  @doc """
  Store a document to a `file://` URL with the given export filter.

  Common filters: `"writer_pdf_Export"`, `"calc_pdf_Export"`, `"impress_pdf_Export"`.
  """
  def store_to_url!(%__MODULE__{} = conn, doc_oid, url, filter \\ "writer_pdf_Export") do
    qi!(
      conn,
      P.request(@func_query_interface,
        type: {:cached, 1},
        oid: {doc_oid, 5}
      ),
      P.type_new(@xi_storable2, 7)
    )

    # storeToURL — funcID 8: XInterface(0-2) + XStorable(3-8)
    P.send_frame(
      conn.sock,
      P.request(8, type: {:new, @xi_storable2, 8}) <>
        P.null_ctx() <>
        P.enc_str(url) <>
        <<1>> <>
        P.property("FilterName", @tc_string, P.enc_str(filter))
    )

    <<0x80>> = recv_reply!(conn.sock)
  end

  @doc "Close a loaded document, releasing soffice resources."
  def close_document!(%__MODULE__{} = conn, doc_oid) do
    qi!(
      conn,
      P.request(@func_query_interface,
        type: {:cached, 1},
        oid: {doc_oid, 6}
      ),
      P.type_new(@xi_closeable, 9)
    )

    # close(deliverOwnership=true)
    # funcID 5: XInterface(0-2) + XCloseBroadcaster(3-4) + XCloseable(5)
    P.send_frame(
      conn.sock,
      P.request(5, type: {:cached, 9}) <>
        P.null_ctx() <> <<1>>
    )

    recv_reply!(conn.sock)
  end

  @doc """
  Load a document from in-memory bytes via XInputStream.

  No shared filesystem needed — bytes are streamed over the URP socket.
  soffice calls `readBytes()` on our exported stream object.

  Returns the document OID.
  """
  def load_document_stream!(%__MODULE__{} = conn, bytes) when is_binary(bytes) do
    load_from_input_source!(conn, bytes)
  end

  @doc """
  Load a document from a local file via XInputStream.

  Like `load_document_stream!/2` but reads from a file on demand instead of
  holding the entire document in memory. The file must be accessible to the
  Elixir node (not soffice).

  Returns the document OID.
  """
  def load_document_file_stream!(%__MODULE__{} = conn, path) when is_binary(path) do
    %{size: size} = File.stat!(path)
    fd = File.open!(path, [:read, :binary, :raw])

    try do
      load_from_input_source!(conn, {:file, fd, size})
    after
      File.close(fd)
    end
  end

  defp load_from_input_source!(conn, source) do
    stream_oid = "elixir-in-#{:erlang.unique_integer([:positive])}"

    qi!(
      conn,
      P.request(@func_query_interface,
        type: {:cached, 1},
        oid: {conn.desktop_oid, 4}
      ),
      P.type_new(@xi_component_loader, 5)
    )

    # loadComponentFromURL("private:stream", "_blank", 0, [Hidden, InputStream])
    # funcID 3 on XComponentLoader
    P.send_frame(
      conn.sock,
      P.request(3, type: {:new, @xi_component_loader, 6}) <>
        P.null_ctx() <>
        P.enc_str("private:stream") <>
        P.enc_str("_blank") <>
        <<0::32>> <>
        <<2>> <>
        P.property("Hidden", @tc_boolean, <<1>>) <>
        P.property(
          "InputStream",
          @tc_interface ||| @tc_new,
          <<10::16>> <>
            P.enc_str(@xi_input_stream) <>
            P.enc_str(stream_oid) <> <<10::16>>
        )
    )

    # soffice will call readBytes/available/closeInput on our stream
    reply = URP.Stream.recv_handling_input(conn.sock, source)

    case P.parse_interface_reply(reply) do
      nil -> raise "loadComponentFromURL(stream) returned null"
      oid -> oid
    end
  end

  @doc """
  Store a document to in-memory bytes via XOutputStream.

  No shared filesystem needed — PDF bytes are streamed back over the URP socket.
  soffice calls `writeBytes()` on our exported stream object.

  Returns the output bytes (e.g. PDF content).
  """
  def store_to_stream!(%__MODULE__{} = conn, doc_oid, filter \\ "writer_pdf_Export") do
    stream_oid = "elixir-out-#{:erlang.unique_integer([:positive])}"

    qi!(
      conn,
      P.request(@func_query_interface,
        type: {:cached, 1},
        oid: {doc_oid, 5}
      ),
      P.type_new(@xi_storable2, 7)
    )

    # storeToURL("private:stream", [FilterName, OutputStream])
    # funcID 8: XInterface(0-2) + XStorable(3-8)
    P.send_frame(
      conn.sock,
      P.request(8, type: {:new, @xi_storable2, 8}) <>
        P.null_ctx() <>
        P.enc_str("private:stream") <>
        <<2>> <>
        P.property("FilterName", @tc_string, P.enc_str(filter)) <>
        P.property(
          "OutputStream",
          @tc_interface ||| @tc_new,
          <<11::16>> <>
            P.enc_str(@xi_output_stream) <>
            P.enc_str(stream_oid) <> <<11::16>>
        )
    )

    # soffice will call writeBytes/flush/closeOutput on our stream
    {_reply, output_bytes} = URP.Stream.recv_handling_output(conn.sock)
    output_bytes
  end

  ## Handshake

  # Both sides send requestChange simultaneously. We use the minimum signed
  # int32 nonce to guarantee we lose, letting soffice drive commitChange.
  defp handshake!(%__MODULE__{sock: sock}) do
    P.recv_frame(sock)

    P.send_frame(
      sock,
      P.request(@func_request_change,
        type: {:new, @xi_protocol_props, 0},
        oid: {"UrpProtocolProperties", 0},
        tid: {".UrpProtocolPropertiesTid", 0}
      ) <> @losing_nonce
    )

    <<0x80, 0::32>> = P.recv_frame(sock)
    P.send_frame(sock, P.reply(<<1::32-signed>>))
    P.recv_frame(sock)
    P.send_frame(sock, P.reply())
  end

  ## Bootstrap Desktop — ComponentContext → ServiceManager → Desktop

  defp bootstrap_desktop!(%__MODULE__{sock: sock}) do
    tid = :crypto.strong_rand_bytes(20)

    ctx_oid =
      qi!(
        sock,
        P.request(@func_query_interface,
          type: {:new, @xi_interface, 1},
          oid: {"StarOffice.ComponentContext", 1},
          tid: {tid, 1}
        ),
        P.type_cached(1)
      )

    qi!(
      sock,
      P.request(@func_query_interface, oid: {ctx_oid, 2}),
      P.type_new(@xi_component_ctx, 2)
    )

    # getServiceManager — funcID 4 on XComponentContext
    P.send_frame(
      sock,
      P.request(4, type: {:new, @xi_component_ctx, 3}) <> P.null_ctx()
    )

    smgr_oid = P.parse_interface_reply(P.recv_frame(sock))

    # createInstanceWithContext("com.sun.star.frame.Desktop")
    # funcID 3 on XMultiComponentFactory
    P.send_frame(
      sock,
      P.request(3,
        type: {:new, @xi_multi_comp_fac, 4},
        oid: {smgr_oid, 3}
      ) <>
        P.null_ctx() <>
        P.enc_str("com.sun.star.frame.Desktop") <>
        <<0x00, 2::16>>
    )

    P.parse_interface_reply(P.recv_frame(sock))
  end

  ## queryInterface helper

  defp qi!(%__MODULE__{sock: sock}, header, body_type_param) do
    qi!(sock, header, body_type_param)
  end

  defp qi!(sock, header, body_type_param) do
    P.send_frame(sock, header <> P.null_ctx() <> body_type_param)
    P.parse_qi_reply(recv_reply!(sock))
  end

  ## Dispatching recv — handles stray incoming requests (e.g. release() on
  ## exported stream objects) with a void reply, until we get the actual reply.

  defp recv_reply!(sock) do
    payload = P.recv_frame(sock)

    if P.is_reply?(payload) do
      payload
    else
      P.send_frame(sock, P.reply())
      recv_reply!(sock)
    end
  end
end

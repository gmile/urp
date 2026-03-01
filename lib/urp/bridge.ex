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
      URP.Bridge.close!(conn)
  """

  alias URP.Protocol, as: P

  @type t :: %__MODULE__{sock: :gen_tcp.socket(), desktop_oid: String.t(), ctx_oid: String.t()}
  @type doc_oid :: String.t()

  defstruct [:sock, :desktop_oid, :ctx_oid]

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
  @xi_multi_service_factory "com.sun.star.lang.XMultiServiceFactory"
  @xi_name_access "com.sun.star.container.XNameAccess"

  # Special function IDs — binaryurp/source/specialfunctionids.hxx
  @func_query_interface 0
  @func_request_change 4

  import Bitwise

  # UNO TypeClass values for property encoding — include/typelib/typeclass.h
  @tc_boolean 2
  @tc_string 12
  @tc_struct 17
  @tc_interface 22
  @tc_new 0x80

  # Minimum signed int32 — guarantees we lose the nonce negotiation
  @losing_nonce <<-2_147_483_648::32-signed>>

  @doc "Connect to soffice, perform URP handshake, and bootstrap a Desktop reference."
  @spec open!(String.t(), non_neg_integer()) :: t()
  def open!(host \\ "localhost", port \\ 2002) do
    {:ok, sock} = :gen_tcp.connect(String.to_charlist(host), port, [:binary, active: false])
    conn = %__MODULE__{sock: sock}
    handshake!(conn)
    {ctx_oid, desktop_oid} = bootstrap_desktop!(conn)
    %{conn | desktop_oid: desktop_oid, ctx_oid: ctx_oid}
  end

  @doc "Close the TCP connection."
  @spec close!(t()) :: :ok
  def close!(%__MODULE__{sock: sock}) do
    :gen_tcp.close(sock)
  end

  @doc """
  Load a document from a `file://` URL. Returns the document OID.

  Raises if soffice cannot open the file.
  """
  @spec load_document!(t(), String.t()) :: doc_oid()
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

    reply = recv_reply!(conn.sock)

    case P.parse_interface_reply(reply) do
      nil ->
        raise "loadComponentFromURL failed: #{P.parse_exception(reply)}"

      oid ->
        oid
    end
  end

  @doc """
  Store a document to a `file://` URL with the given [export filter](https://help.libreoffice.org/latest/en-US/text/shared/guide/convertfilters.html).

  Common filters: `"writer_pdf_Export"`, `"calc_pdf_Export"`, `"impress_pdf_Export"`.
  """
  @spec store_to_url!(t(), doc_oid(), String.t(), String.t()) :: nil
  def store_to_url!(%__MODULE__{} = conn, doc_oid, url, filter) do
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

    reply = recv_reply!(conn.sock)

    if reply != <<0x80>> do
      raise "storeToURL failed: #{P.parse_exception(reply)}"
    end
  end

  @doc "Close a loaded document, releasing soffice resources."
  @spec close_document!(t(), doc_oid()) :: binary()
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
  Query the soffice version string over URP.

  Reads `ooSetupVersionAboutBox` from the configuration API via 5 UNO
  round trips. Returns a string like `"25.8.1.1"`. Does not consume
  the connection (no streaming).
  """
  @spec version!(t()) :: String.t()
  def version!(%__MODULE__{} = conn) do
    sock = conn.sock

    # Step 1: getValueByName("/singletons/com.sun.star.configuration.theDefaultProvider")
    # funcID 3 on XComponentContext (XInterface 0-2, getValueByName 3, getServiceManager 4)
    P.send_frame(
      sock,
      P.request(3,
        type: {:cached, 3},
        oid: {conn.ctx_oid, 2}
      ) <>
        P.null_ctx() <>
        P.enc_str("/singletons/com.sun.star.configuration.theDefaultProvider")
    )

    reply = recv_reply!(sock)

    config_provider_oid =
      P.parse_qi_reply(reply) ||
        raise "getValueByName(theDefaultProvider) failed: #{P.parse_exception(reply)}"

    # Step 2: QI ConfigProvider for XMultiServiceFactory
    qi!(
      conn,
      P.request(@func_query_interface,
        type: {:cached, 1},
        oid: {config_provider_oid, 7}
      ),
      P.type_new(@xi_multi_service_factory, 12)
    )

    # Step 3: createInstanceWithArguments("...ConfigurationAccess", [NamedValue("nodepath", ...)])
    # funcID 4 on XMultiServiceFactory (XInterface 0-2, createInstance 3, createInstanceWithArguments 4)
    P.send_frame(
      sock,
      # sequence<any> with 1 element: any(NamedValue)
      P.request(4, type: {:new, @xi_multi_service_factory, 13}) <>
        P.null_ctx() <>
        P.enc_str("com.sun.star.configuration.ConfigurationAccess") <>
        <<1>> <>
        <<@tc_struct ||| @tc_new, 14::16>> <>
        P.enc_str("com.sun.star.beans.NamedValue") <>
        P.enc_str("nodepath") <>
        <<@tc_string>> <>
        P.enc_str("/org.openoffice.Setup/Product")
    )

    reply = recv_reply!(sock)

    config_access_oid =
      P.parse_interface_reply(reply) ||
        raise "createInstanceWithArguments(ConfigurationAccess) failed: #{P.parse_exception(reply)}"

    # Step 4: QI ConfigAccess for XNameAccess
    qi!(
      conn,
      P.request(@func_query_interface,
        type: {:cached, 1},
        oid: {config_access_oid, 8}
      ),
      P.type_new(@xi_name_access, 15)
    )

    # Step 5: getByName("ooSetupVersionAboutBox")
    # funcID 5 on XNameAccess (XInterface 0-2, XElementAccess 3-4, getByName 5)
    P.send_frame(
      sock,
      P.request(5, type: {:new, @xi_name_access, 16}) <>
        P.null_ctx() <>
        P.enc_str("ooSetupVersionAboutBox")
    )

    reply = recv_reply!(sock)

    P.parse_any_string_reply(reply) ||
      raise "getByName(ooSetupVersionAboutBox) failed: #{P.parse_exception(reply)}"
  end

  @doc """
  Load a document from in-memory bytes via XInputStream.

  No shared filesystem needed — bytes are streamed over the URP socket.
  soffice calls `readBytes()` on our exported stream object.

  Returns the document OID.
  """
  @spec load_document_stream!(t(), binary()) :: doc_oid()
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
  @spec load_document_file_stream!(t(), Path.t()) :: doc_oid()
  def load_document_file_stream!(%__MODULE__{} = conn, path) when is_binary(path) do
    %{size: size} = File.stat!(path)
    fd = File.open!(path, [:read, :binary, :raw])

    try do
      load_from_input_source!(conn, {:file, fd, size})
    after
      File.close(fd)
    end
  end

  @doc """
  Load a document from an enumerable via XInputStream.

  Like `load_document_stream!/2` but pulls chunks lazily from any `Enumerable`
  (e.g. `File.stream!/2`, an S3 download stream). The enumerable is iterated
  in a linked process; chunks are buffered and fed to soffice on demand.

  Returns the document OID.
  """
  @spec load_document_enum_stream!(t(), Enumerable.t()) :: doc_oid()
  def load_document_enum_stream!(%__MODULE__{} = conn, enumerable) do
    reader = URP.Stream.start_enum_reader(enumerable)

    try do
      load_from_input_source!(conn, {:enum, <<>>, reader})
    after
      Process.unlink(reader)
      Process.exit(reader, :kill)
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

    # soffice will call readBytes/available/closeInput/seek/getPosition/getLength on our stream
    reply = URP.Stream.recv_handling_input(conn.sock, source, stream_oid)

    case P.parse_interface_reply(reply) do
      nil -> raise "loadComponentFromURL(stream) failed: #{P.parse_exception(reply)}"
      oid -> oid
    end
  end

  @doc """
  Store a document via XOutputStream.

  No shared filesystem needed — output bytes are streamed back over the URP socket.
  soffice calls `writeBytes()` on our exported stream object.

  `sink` controls where output goes:

    * `nil` (default) — accumulate in memory, returns the output bytes
    * `{:path, path}` — write to file as chunks arrive, returns `:ok`
    * `fun/1` — call with each chunk as it arrives, returns `:ok`
  """
  @spec store_to_stream!(t(), doc_oid(), keyword()) :: binary() | :ok
  def store_to_stream!(%__MODULE__{} = conn, doc_oid, opts \\ []) do
    filter = Keyword.fetch!(opts, :filter)
    sink = Keyword.get(opts, :sink)
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
    {_reply, result} = URP.Stream.recv_handling_output(conn.sock, sink)
    result
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

    desktop_oid = P.parse_interface_reply(P.recv_frame(sock))
    {ctx_oid, desktop_oid}
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
  ## One-way calls (like release) must not receive a reply.

  defp recv_reply!(sock) do
    payload = P.recv_frame(sock)

    if P.is_reply?(payload) do
      payload
    else
      case URP.Stream.try_handle_input(sock, payload) do
        :handled ->
          :ok

        :not_input ->
          %{func_id: func_id, tid: new_tid} = P.parse_request(payload)
          tid = URP.Stream.track_tid(new_tid)

          unless P.one_way?(func_id),
            do: P.send_frame(sock, URP.Stream.inject_tid(P.reply(), tid))
      end

      recv_reply!(sock)
    end
  end
end

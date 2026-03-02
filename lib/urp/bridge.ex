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

  @type t :: %__MODULE__{
          sock: :gen_tcp.socket(),
          desktop_oid: String.t(),
          ctx_oid: String.t(),
          smgr_oid: String.t(),
          sfa_oid: String.t() | nil,
          tid_cache: map()
        }
  @type doc_oid :: String.t()

  defstruct [:sock, :desktop_oid, :ctx_oid, :smgr_oid, :sfa_oid, tid_cache: %{}]

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
  @xi_simple_file_access "com.sun.star.ucb.XSimpleFileAccess"

  # Special function IDs — binaryurp/source/specialfunctionids.hxx
  @func_query_interface 0
  @func_request_change 4

  # Per-interface function IDs — counted from XInterface(0-2), then IDL order.
  # XComponentLoader: loadComponentFromURL=3
  @func_loader_load 3
  # XComponentContext: getValueByName=3, getServiceManager=4
  @func_ctx_get_value_by_name 3
  @func_ctx_get_service_manager 4
  # XMultiComponentFactory: createInstanceWithContext=3
  @func_mcf_create_with_context 3
  # XStorable2: storeToURL=8 (XInterface 0-2, XStorable 3-7, storeToURL 8)
  @func_storable_store_to_url 8
  # XCloseable: close=5 (XInterface 0-2, XCloseBroadcaster 3-4, close 5)
  @func_closeable_close 5
  # XMultiServiceFactory: createInstanceWithArguments=4
  @func_msf_create_with_args 4
  # XNameAccess: getByName=5 (XInterface 0-2, XElementAccess 3-4, getByName 5)
  @func_na_get_by_name 5
  # XSimpleFileAccess (XInterface 0-2, then IDL order):
  # copy=3, move=4, kill=5, isFolder=6, ..., openFileRead=15, openFileWrite=16
  @func_sfa_kill 5
  @func_sfa_open_file_read 15
  @func_sfa_open_file_write 16
  # XInputStream: readBytes=3, ..., closeInput=7
  @func_is_read_bytes 3
  @func_is_close_input 7
  # XOutputStream: writeBytes=3, flush=4, closeOutput=5
  @func_os_write_bytes 3
  @func_os_close_output 5

  # Maximum signed int32 — used with readBytes to pull entire file in one frame
  @max_read_bytes 0x7FFFFFFF

  # URP type cache — sequential allocation shared between request headers and QI bodies.
  #
  #  idx | interface/struct                    | registered by
  # -----+------------------------------------+--------------------
  #   0  | XProtocolProperties                | handshake
  #   1  | XInterface                         | bootstrap
  #   2  | XComponentContext                   | bootstrap QI body
  #   3  | XComponentContext                   | getServiceManager header
  #   4  | XMultiComponentFactory             | createInstanceWithContext header
  #   5  | XComponentLoader                   | load QI body
  #   6  | XComponentLoader                   | loadComponentFromURL header
  #   7  | XStorable2                         | store QI body
  #   8  | XStorable2                         | storeToURL header
  #   9  | XCloseable                         | close QI body + close header
  #  10  | XInputStream                       | exported stream property
  #  11  | XOutputStream                      | exported stream property
  #  12  | XMultiServiceFactory               | version QI body
  #  13  | XMultiServiceFactory               | createInstanceWithArgs header
  #  14  | NamedValue struct                   | version config access
  #  15  | XNameAccess                        | version QI body
  #  16  | XNameAccess                        | getByName header
  #  18  | []PropertyValue                    | FilterData encoding
  #  19  | XSimpleFileAccess                  | SFA QI body + method headers
  #  20  | XOutputStream                      | SFA write QI body + method headers
  #  21  | XInputStream                       | SFA read QI body + method headers

  # Request header type tuples — {:cached, idx} or {:new, name, idx}
  @type_interface {:cached, 1}
  @type_component_ctx {:cached, 3}
  @type_multi_comp_fac {:cached, 4}
  @type_closeable {:cached, 9}
  @type_sfa {:cached, 19}
  @type_os_sfa {:cached, 20}
  @type_is_sfa {:cached, 21}
  @type_new_protocol_props {:new, @xi_protocol_props, 0}
  @type_new_interface {:new, @xi_interface, 1}
  @type_new_component_ctx {:new, @xi_component_ctx, 3}
  @type_new_multi_comp_fac {:new, @xi_multi_comp_fac, 4}
  @type_new_loader {:new, @xi_component_loader, 6}
  @type_new_storable {:new, @xi_storable2, 8}
  @type_new_msf {:new, @xi_multi_service_factory, 13}
  @type_new_name_access {:new, @xi_name_access, 16}

  # OID cache indices — sequential allocation for object identity references
  @oid_ctx 2
  @oid_smgr 3
  @oid_desktop 4
  @oid_doc_storable 5
  @oid_doc_closeable 6
  @oid_config_provider 7
  @oid_config_access 8
  @oid_sfa 9
  @oid_sfa_os 12
  @oid_sfa_is 13

  import Bitwise

  # UNO TypeClass values for property encoding — include/typelib/typeclass.h
  @tc_boolean 2
  @tc_long 6
  @tc_string 12
  @tc_struct 17
  @tc_sequence 20
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
    {ctx_oid, smgr_oid, desktop_oid} = bootstrap_desktop!(conn)
    tid_cache = Process.get(:urp_tid_cache, %{})
    %{conn | desktop_oid: desktop_oid, ctx_oid: ctx_oid, smgr_oid: smgr_oid, tid_cache: tid_cache}
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
        type: @type_interface,
        oid: {conn.desktop_oid, @oid_desktop}
      ),
      P.type_new(@xi_component_loader, 5)
    )

    # loadComponentFromURL(url, "_blank", 0, [Hidden=true])
    P.send_frame(
      conn.sock,
      P.request(@func_loader_load, type: @type_new_loader) <>
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

  `filter_data` is an optional keyword list of export-specific options passed
  as a nested `FilterData` property (e.g. `[UseLosslessCompression: true]`).
  """
  @spec store_to_url!(t(), doc_oid(), String.t(), String.t(), keyword()) :: nil
  def store_to_url!(%__MODULE__{} = conn, doc_oid, url, filter, filter_data \\ []) do
    qi!(
      conn,
      P.request(@func_query_interface,
        type: @type_interface,
        oid: {doc_oid, @oid_doc_storable}
      ),
      P.type_new(@xi_storable2, 7)
    )

    filter_data_bin = encode_filter_data(filter_data)
    prop_count = if filter_data == [], do: 1, else: 2

    # storeToURL
    P.send_frame(
      conn.sock,
      P.request(@func_storable_store_to_url, type: @type_new_storable) <>
        P.null_ctx() <>
        P.enc_str(url) <>
        <<prop_count>> <>
        P.property("FilterName", @tc_string, P.enc_str(filter)) <>
        filter_data_bin
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
        type: @type_interface,
        oid: {doc_oid, @oid_doc_closeable}
      ),
      P.type_new(@xi_closeable, 9)
    )

    # close(deliverOwnership=true)
    P.send_frame(
      conn.sock,
      P.request(@func_closeable_close, type: @type_closeable) <>
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
    P.send_frame(
      sock,
      P.request(@func_ctx_get_value_by_name,
        type: @type_component_ctx,
        oid: {conn.ctx_oid, @oid_ctx}
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
        type: @type_interface,
        oid: {config_provider_oid, @oid_config_provider}
      ),
      P.type_new(@xi_multi_service_factory, 12)
    )

    # Step 3: createInstanceWithArguments("...ConfigurationAccess", [NamedValue("nodepath", ...)])
    P.send_frame(
      sock,
      P.request(@func_msf_create_with_args, type: @type_new_msf) <>
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
        type: @type_interface,
        oid: {config_access_oid, @oid_config_access}
      ),
      P.type_new(@xi_name_access, 15)
    )

    # Step 5: getByName("ooSetupVersionAboutBox")
    P.send_frame(
      sock,
      P.request(@func_na_get_by_name, type: @type_new_name_access) <>
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

  @doc """
  Load a document by writing bytes to soffice's filesystem via XSimpleFileAccess.

  Instead of streaming bytes through XInputStream (which causes thousands of
  tiny read/seek round-trips), this writes the entire document to a temp file
  on soffice's filesystem and loads from a `file://` URL.

  Returns `{doc_oid, updated_conn, temp_url}`. The caller must delete the temp
  file after conversion via `delete_file!/2`.
  """
  @spec load_document_write!(t(), binary()) :: {doc_oid(), t(), String.t()}
  def load_document_write!(%__MODULE__{} = conn, bytes) when is_binary(bytes) do
    # Seed the TID read cache (bootstrap ran in pool worker, we're in checkout process)
    if conn.tid_cache != %{} do
      existing = Process.get(:urp_tid_cache, %{})
      Process.put(:urp_tid_cache, Map.merge(conn.tid_cache, existing))
    end

    {sfa_oid, conn} = ensure_sfa!(conn)
    id = :erlang.unique_integer([:positive])
    url = "file:///tmp/urp_in_#{id}"

    # openFileWrite(url) → XOutputStream
    P.send_frame(
      conn.sock,
      P.request(@func_sfa_open_file_write, type: @type_sfa, oid: {sfa_oid, @oid_sfa}) <>
        P.null_ctx() <> P.enc_str(url)
    )

    os_oid =
      P.parse_interface_reply(recv_reply!(conn.sock)) ||
        raise "openFileWrite failed"

    # QI for XOutputStream
    qi!(
      conn,
      P.request(@func_query_interface, type: @type_interface, oid: {os_oid, @oid_sfa_os}),
      P.type_new(@xi_output_stream, 20)
    )

    # writeBytes(bytes) — single URP frame with all data
    P.send_frame(
      conn.sock,
      P.request(@func_os_write_bytes, type: @type_os_sfa) <>
        P.null_ctx() <> P.enc_str(bytes)
    )

    recv_reply!(conn.sock)

    # closeOutput()
    P.send_frame(
      conn.sock,
      P.request(@func_os_close_output) <> P.null_ctx()
    )

    recv_reply!(conn.sock)

    # loadComponentFromURL(url, ...)
    doc_oid = load_document!(conn, url)

    {doc_oid, conn, url}
  end

  @doc "Delete a temp file on soffice's filesystem via XSimpleFileAccess.kill()."
  @spec delete_file!(t(), String.t()) :: :ok
  def delete_file!(%__MODULE__{sfa_oid: sfa_oid} = conn, url) when is_binary(sfa_oid) do
    P.send_frame(
      conn.sock,
      P.request(@func_sfa_kill, type: @type_sfa, oid: {sfa_oid, @oid_sfa}) <>
        P.null_ctx() <> P.enc_str(url)
    )

    recv_reply!(conn.sock)
    :ok
  end

  @doc """
  Store a document to soffice's filesystem and read back the result.

  Uses `store_to_url!` to write the converted output to a temp file on
  soffice's filesystem, then reads it back in one shot via `read_file!/2`.
  Replaces hundreds of round-trips with ~6.
  """
  @spec store_document_write!(t(), doc_oid(), keyword()) :: {binary(), t()}
  def store_document_write!(%__MODULE__{} = conn, doc_oid, opts) do
    filter = Keyword.fetch!(opts, :filter)
    filter_data = Keyword.get(opts, :filter_data, [])
    id = :erlang.unique_integer([:positive])
    url = "file:///tmp/urp_out_#{id}"

    store_to_url!(conn, doc_oid, url, filter, filter_data)
    {bytes, conn} = read_file!(conn, url)
    delete_file!(conn, url)

    {bytes, conn}
  end

  @doc """
  Read a file from soffice's filesystem via XSimpleFileAccess.

  Opens the file, reads all bytes in one frame, closes the stream.
  """
  @spec read_file!(t(), String.t()) :: {binary(), t()}
  def read_file!(%__MODULE__{} = conn, url) do
    {sfa_oid, conn} = ensure_sfa!(conn)

    # openFileRead(url) → XInputStream
    P.send_frame(
      conn.sock,
      P.request(@func_sfa_open_file_read, type: @type_sfa, oid: {sfa_oid, @oid_sfa}) <>
        P.null_ctx() <> P.enc_str(url)
    )

    is_oid =
      P.parse_interface_reply(recv_reply!(conn.sock)) ||
        raise "openFileRead failed"

    # QI for XInputStream
    qi!(
      conn,
      P.request(@func_query_interface, type: @type_interface, oid: {is_oid, @oid_sfa_is}),
      P.type_new(@xi_input_stream, 21)
    )

    # readBytes(max_int32) — pull entire file in one frame
    P.send_frame(
      conn.sock,
      P.request(@func_is_read_bytes, type: @type_is_sfa) <>
        P.null_ctx() <> <<@max_read_bytes::32-signed>>
    )

    bytes = P.parse_read_bytes_reply(recv_reply!(conn.sock))

    # closeInput()
    P.send_frame(
      conn.sock,
      P.request(@func_is_close_input) <> P.null_ctx()
    )

    recv_reply!(conn.sock)

    {bytes, conn}
  end

  defp load_from_input_source!(conn, source) do
    # Seed the TID read cache with entries from bootstrap (which ran in the pool worker process)
    if conn.tid_cache != %{} do
      existing = Process.get(:urp_tid_cache, %{})
      Process.put(:urp_tid_cache, Map.merge(conn.tid_cache, existing))
    end

    stream_oid = "elixir-in-#{:erlang.unique_integer([:positive])}"

    qi!(
      conn,
      P.request(@func_query_interface,
        type: @type_interface,
        oid: {conn.desktop_oid, @oid_desktop}
      ),
      P.type_new(@xi_component_loader, 5)
    )

    # loadComponentFromURL("private:stream", "_blank", 0, [Hidden, InputStream])
    P.send_frame(
      conn.sock,
      P.request(@func_loader_load, type: @type_new_loader) <>
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
    filter_data = Keyword.get(opts, :filter_data, [])
    sink = Keyword.get(opts, :sink)
    stream_oid = "elixir-out-#{:erlang.unique_integer([:positive])}"

    qi!(
      conn,
      P.request(@func_query_interface,
        type: @type_interface,
        oid: {doc_oid, @oid_doc_storable}
      ),
      P.type_new(@xi_storable2, 7)
    )

    filter_data_bin = encode_filter_data(filter_data)
    prop_count = if filter_data == [], do: 2, else: 3

    # storeToURL("private:stream", [FilterName, FilterData?, OutputStream])
    P.send_frame(
      conn.sock,
      P.request(@func_storable_store_to_url, type: @type_new_storable) <>
        P.null_ctx() <>
        P.enc_str("private:stream") <>
        <<prop_count>> <>
        P.property("FilterName", @tc_string, P.enc_str(filter)) <>
        filter_data_bin <>
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

  ## SimpleFileAccess — lazily created for write-based document loading

  defp ensure_sfa!(%__MODULE__{sfa_oid: oid} = conn) when is_binary(oid), do: {oid, conn}

  defp ensure_sfa!(%__MODULE__{} = conn) do
    # createInstanceWithContext on smgr
    P.send_frame(
      conn.sock,
      P.request(@func_mcf_create_with_context, type: @type_multi_comp_fac, oid: {conn.smgr_oid, @oid_smgr}) <>
        P.null_ctx() <>
        P.enc_str("com.sun.star.ucb.SimpleFileAccess") <>
        <<0x00, 2::16>>
    )

    sfa_oid =
      P.parse_interface_reply(recv_reply!(conn.sock)) ||
        raise "createInstanceWithContext(SimpleFileAccess) failed"

    # QI for XSimpleFileAccess
    qi!(
      conn,
      P.request(@func_query_interface, type: @type_interface, oid: {sfa_oid, @oid_sfa}),
      P.type_new(@xi_simple_file_access, 19)
    )

    conn = %{conn | sfa_oid: sfa_oid}
    {sfa_oid, conn}
  end

  ## Handshake

  # Both sides send requestChange simultaneously. We use the minimum signed
  # int32 nonce to guarantee we lose, letting soffice drive commitChange.
  defp handshake!(%__MODULE__{sock: sock}) do
    P.recv_frame(sock)

    P.send_frame(
      sock,
      P.request(@func_request_change,
        type: @type_new_protocol_props,
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
          type: @type_new_interface,
          oid: {"StarOffice.ComponentContext", 1},
          tid: {tid, 1}
        ),
        P.type_cached(1)
      )

    qi!(
      sock,
      P.request(@func_query_interface, oid: {ctx_oid, @oid_ctx}),
      P.type_new(@xi_component_ctx, 2)
    )

    # getServiceManager
    P.send_frame(
      sock,
      P.request(@func_ctx_get_service_manager, type: @type_new_component_ctx) <> P.null_ctx()
    )

    smgr_oid = P.parse_interface_reply(P.recv_frame(sock))

    # createInstanceWithContext("com.sun.star.frame.Desktop")
    P.send_frame(
      sock,
      P.request(@func_mcf_create_with_context,
        type: @type_new_multi_comp_fac,
        oid: {smgr_oid, @oid_smgr}
      ) <>
        P.null_ctx() <>
        P.enc_str("com.sun.star.frame.Desktop") <>
        <<0x00, 2::16>>
    )

    desktop_oid = P.parse_interface_reply(P.recv_frame(sock))
    {ctx_oid, smgr_oid, desktop_oid}
  end

  ## queryInterface helper

  defp qi!(%__MODULE__{sock: sock}, header, body_type_param) do
    qi!(sock, header, body_type_param)
  end

  defp qi!(sock, header, body_type_param) do
    P.send_frame(sock, header <> P.null_ctx() <> body_type_param)
    P.parse_qi_reply(recv_reply!(sock))
  end

  ## FilterData encoding — nested sequence<PropertyValue> for export options

  defp encode_filter_data([]), do: <<>>

  defp encode_filter_data(filter_data) do
    inner =
      for {name, value} <- filter_data, into: <<>> do
        {tc, bytes} = encode_any_value(value)
        P.property(to_string(name), tc, bytes)
      end

    P.property(
      "FilterData",
      @tc_sequence ||| @tc_new,
      <<18::16>> <>
        P.enc_str("[]com.sun.star.beans.PropertyValue") <>
        <<length(filter_data)>> <>
        inner
    )
  end

  defp encode_any_value(true), do: {@tc_boolean, <<1>>}
  defp encode_any_value(false), do: {@tc_boolean, <<0>>}
  defp encode_any_value(n) when is_integer(n), do: {@tc_long, <<n::32-signed>>}
  defp encode_any_value(s) when is_binary(s), do: {@tc_string, P.enc_str(s)}

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

defmodule URP.Bridge do
  @moduledoc """
  Mid-level UNO operations over a URP connection.

  Manages a TCP connection to a `soffice` process and provides functions for
  the UNO operations needed for document conversion: loading documents,
  storing to URL, and closing.

  Each connection performs a handshake and bootstraps a Desktop reference
  on `open/2`. A connection handles one conversion at a time. LibreOffice can
  accept multiple connections, but they share process-wide state and much of
  the document core is serialized internally. Close the connection with
  `close!/1` when done.

  All functions take and return `conn`, following the Plug pattern. Document
  OIDs and conversion state are stashed on the conn struct — no separate
  values to track.

  ## Example

      "localhost"
      |> URP.Bridge.open(2002)
      |> URP.Bridge.load_document("file:///tmp/input.docx")
      |> URP.Bridge.store_to_url("file:///tmp/output.pdf", "writer_pdf_Export")
      |> URP.Bridge.close_document()
      |> URP.Bridge.close!()

  ## Streaming

  `load_document_stream/2` and `store_to_stream/2` use UNO's
  `XInputStream`/`XOutputStream` interfaces to transfer document bytes
  over the URP socket, eliminating the need for a shared filesystem.

      conn =
        "localhost"
        |> URP.Bridge.open(2002)
        |> URP.Bridge.load_document_stream(File.read!("input.docx"))
        |> URP.Bridge.store_to_stream(filter: "writer_pdf_Export")

      pdf = conn.reply
      URP.Bridge.close!(conn)

  ## Private storage

  Diagnostic functions stash results in `conn.private`:

      conn =
        "localhost"
        |> URP.Bridge.open(2002)
        |> URP.Bridge.version()

      conn.private.version
      # => "26.2.0.3"
  """

  alias URP.Protocol, as: P
  alias URP.Call, as: C

  # sock is a plain :gen_tcp socket — inspect at any time via:
  #   :inet.getstat(conn.sock)   # send/recv counts, bytes, pending
  #   :inet.peername(conn.sock)  # remote {ip, port}
  @type t :: %__MODULE__{
          sock: :gen_tcp.socket() | nil,
          desktop_oid: String.t() | nil,
          ctx_oid: String.t() | nil,
          smgr_oid: String.t() | nil,
          doc_oid: String.t() | nil,
          cleanup_url: String.t() | nil,
          sfa_oid: String.t() | nil,
          input_ctx: map() | nil,
          reply_tid: binary() | nil,
          reader_type: non_neg_integer() | nil,
          recv_timeout: timeout(),
          max_frame_size: pos_integer(),
          reply: term(),
          error: String.t() | atom() | nil,
          tid_cache: map(),
          oid_cache: map(),
          private: map()
        }

  defstruct [
    :sock,
    :desktop_oid,
    :ctx_oid,
    :smgr_oid,
    :doc_oid,
    :cleanup_url,
    :sfa_oid,
    :input_ctx,
    :reply_tid,
    :reader_type,
    :reply,
    :error,
    recv_timeout: 120_000,
    max_frame_size: 512 * 1024 * 1024,
    tid_cache: %{},
    oid_cache: %{},
    private: %{}
  ]

  # Reply marker byte — integer form of P.reply() for use in pattern matching
  @reply_byte 0x80

  # Configuration provider singleton path (used by version and locale)
  @config_provider_path "/singletons/com.sun.star.configuration.theDefaultProvider"
  @cleanup_timeout 1_000
  @default_connect_timeout 5_000
  @default_send_timeout 120_000

  @doc "Connect to soffice, perform URP handshake, and bootstrap a Desktop reference."
  @spec open(String.t(), non_neg_integer(), keyword()) :: t()
  def open(host \\ "localhost", port \\ 2002, opts \\ []) do
    connect_timeout = Keyword.get(opts, :connect_timeout, @default_connect_timeout)
    send_timeout = Keyword.get(opts, :send_timeout, @default_send_timeout)

    socket_opts = [
      :binary,
      active: false,
      send_timeout: send_timeout,
      send_timeout_close: true
    ]

    case :gen_tcp.connect(String.to_charlist(host), port, socket_opts, connect_timeout) do
      {:ok, sock} ->
        init_connection(sock)

      {:error, reason} ->
        %__MODULE__{error: "connection failed: #{:inet.format_error(reason)}"}
    end
  end

  defp init_connection(sock) do
    Process.put(:urp_tid_cache, %{})
    Process.put(:urp_oid_cache, %{})

    %__MODULE__{sock: sock}
    |> handshake!()
    |> bootstrap()
    |> capture_protocol_caches()
  rescue
    e ->
      :gen_tcp.close(sock)
      %__MODULE__{error: "handshake failed: #{Exception.message(e)}"}
  end

  @doc "Close the TCP connection."
  @spec close!(t()) :: :ok
  def close!(%__MODULE__{sock: nil}), do: :ok
  def close!(%__MODULE__{sock: sock}), do: :gen_tcp.close(sock)

  @doc """
  Load a document from a `file://` URL. Stashes the document OID on `conn.doc_oid`.

  On failure, stashes the error on `conn.error`.
  """
  @spec load_document(t(), String.t()) :: t()
  def load_document(%__MODULE__{error: e} = conn, _url) when not is_nil(e), do: conn

  def load_document(%__MODULE__{} = conn, url) do
    conn
    |> call(C.qi_loader(conn.desktop_oid), :qi)
    |> call(C.load_component_from_url(url, [C.hidden_property()]), :interface)
    |> stash(:doc_oid)
  end

  @doc """
  Store a document to a `file://` URL with the given [export filter](https://help.libreoffice.org/latest/en-US/text/shared/guide/convertfilters.html).

  Common filters: `"writer_pdf_Export"`, `"calc_pdf_Export"`, `"impress_pdf_Export"`.

  `filter_data` is an optional keyword list of export-specific options passed
  as a nested `FilterData` property (e.g. `[UseLosslessCompression: true]`).
  """
  @spec store_to_url(t(), String.t(), String.t(), keyword()) :: t()
  def store_to_url(conn, url, filter, filter_data \\ [])

  def store_to_url(%__MODULE__{error: e} = conn, _url, _filter, _filter_data)
      when not is_nil(e),
      do: conn

  def store_to_url(%__MODULE__{doc_oid: doc_oid} = conn, url, filter, filter_data)
      when is_binary(doc_oid) do
    conn
    |> call(C.qi_storable(doc_oid), :qi)
    |> call(C.store_to_url(url, store_props(filter, filter_data)), :void)
  end

  @doc "Close the loaded document, releasing soffice resources."
  @spec close_document(t()) :: t()
  def close_document(%__MODULE__{error: e} = conn) when not is_nil(e), do: conn
  def close_document(%__MODULE__{doc_oid: nil} = conn), do: conn

  def close_document(%__MODULE__{doc_oid: doc_oid} = conn) when is_binary(doc_oid) do
    conn =
      conn
      |> call(C.qi_closeable(doc_oid), :qi)
      |> call(C.close_document(), :void)

    %{conn | doc_oid: nil}
  end

  @doc false
  @spec cleanup(t()) :: t()
  def cleanup(%__MODULE__{} = conn) do
    original_reply = conn.reply
    original_timeout = conn.recv_timeout
    conn = %{conn | recv_timeout: min(original_timeout, @cleanup_timeout)}

    conn =
      if conn.sock && conn.doc_oid do
        attempt_cleanup(conn, &close_document/1)
      else
        %{conn | doc_oid: nil}
      end

    cleanup_url = conn.cleanup_url

    conn =
      if conn.sock && cleanup_url do
        attempt_cleanup(conn, &delete_file(&1, cleanup_url))
      else
        conn
      end

    conn = release_input(conn)

    %{
      conn
      | doc_oid: nil,
        cleanup_url: nil,
        input_ctx: nil,
        reply: original_reply,
        recv_timeout: original_timeout
    }
  end

  @doc false
  @spec release_input(t()) :: t()
  def release_input(%__MODULE__{input_ctx: nil} = conn), do: conn

  def release_input(%__MODULE__{input_ctx: %{source: source}} = conn) do
    release_result =
      case source do
        {:file, fd, _size} -> File.close(fd)
        {:enum, _buffer, reader} -> URP.Stream.stop_enum_reader(reader)
        {:enum, _buffer, reader, _timeout} -> URP.Stream.stop_enum_reader(reader)
        _other -> :ok
      end

    conn = %{conn | input_ctx: nil}

    case {conn.error, release_result} do
      {nil, {:error, reason}} ->
        %{conn | error: "could not release input stream: #{:file.format_error(reason)}"}

      _ ->
        conn
    end
  end

  defp attempt_cleanup(conn, fun) do
    primary_error = conn.error
    cleaned = fun.(%{conn | error: nil, reply: nil})
    %{cleaned | error: primary_error || cleaned.error}
  end

  @doc """
  Query the soffice version string over URP.

  Reads `ooSetupVersionAboutBox` from the configuration API via 5 UNO
  round trips. Stashes the result in `conn.private.version`.
  """
  @spec version(t()) :: t()
  def version(%__MODULE__{error: e} = conn) when not is_nil(e), do: conn

  def version(%__MODULE__{} = conn) do
    conn
    |> call(C.get_value_by_name(conn.ctx_oid, @config_provider_path), :qi)
    |> call_reply(&C.qi_msf/1, :qi)
    |> call(C.create_config_access(), :interface)
    |> call_reply(&C.qi_name_access/1, :qi)
    |> call(C.get_version(), :string)
    |> stash_private(:version)
  end

  @doc """
  List all service names registered in the UNO service manager.

  Calls `XMultiComponentFactory.getAvailableServiceNames()`.
  Stashes the result in `conn.private.services`.
  """
  @spec services(t()) :: t()
  def services(%__MODULE__{error: e} = conn) when not is_nil(e), do: conn

  def services(%__MODULE__{} = conn) do
    conn
    |> call(C.get_available_service_names(conn.smgr_oid), :strings)
    |> stash_private(:services)
  end

  @doc """
  List all export filter names registered in soffice.

  Creates a `FilterFactory` instance and calls `getElementNames()` via `XNameAccess`.
  Stashes the result in `conn.private.filters`.
  """
  @spec filters(t()) :: t()
  def filters(%__MODULE__{error: e} = conn) when not is_nil(e), do: conn

  def filters(%__MODULE__{} = conn) do
    conn =
      call(
        conn,
        C.create_instance_with_context(conn.smgr_oid, "com.sun.star.document.FilterFactory"),
        :interface
      )

    conn
    |> call_reply(&C.qi_ff_name_access/1, :qi)
    |> call(C.get_filter_element_names(), :strings)
    |> stash_private(:filters)
  end

  @doc """
  List all document type names registered in soffice.

  Creates a `TypeDetection` instance and calls `getElementNames()` via `XNameAccess`.
  Stashes the result in `conn.private.types`.
  """
  @spec types(t()) :: t()
  def types(%__MODULE__{error: e} = conn) when not is_nil(e), do: conn

  def types(%__MODULE__{} = conn) do
    conn =
      call(
        conn,
        C.create_instance_with_context(conn.smgr_oid, "com.sun.star.document.TypeDetection"),
        :interface
      )

    conn
    |> call_reply(&C.qi_td_name_access/1, :qi)
    |> call(C.get_type_element_names(), :strings)
    |> stash_private(:types)
  end

  @doc """
  Query the soffice locale string over URP.

  Reads `ooLocale` from `/org.openoffice.Setup/L10N` via the configuration API.
  Stashes the result in `conn.private.locale`.
  """
  @spec locale(t()) :: t()
  def locale(%__MODULE__{error: e} = conn) when not is_nil(e), do: conn

  def locale(%__MODULE__{} = conn) do
    conn
    |> call(C.get_value_by_name(conn.ctx_oid, @config_provider_path), :qi)
    |> call_reply(&C.qi_locale_msf/1, :qi)
    |> call(C.create_locale_config_access(), :interface)
    |> call_reply(&C.qi_locale_na/1, :qi)
    |> call(C.get_locale(), :string)
    |> stash_private(:locale)
  end

  @doc """
  Apply soffice configuration settings via
  [ConfigurationUpdateAccess](https://api.libreoffice.org/docs/idl/ref/servicecom_1_1sun_1_1star_1_1configuration_1_1ConfigurationUpdateAccess.html).

  Each setting is a `{path, property, value}` triplet where `path` is the
  registry node (e.g. `"org.openoffice.Office.Common/Cache/GraphicManager"`),
  `property` is the property name, and `value` is a boolean, integer, or string.

  Settings sharing the same `path` are batched into a single ConfigurationUpdateAccess
  call for efficiency.
  """
  @spec apply_settings(t(), list()) :: t()
  def apply_settings(%__MODULE__{error: e} = conn, _settings) when not is_nil(e), do: conn
  def apply_settings(conn, []), do: conn

  def apply_settings(%__MODULE__{} = conn, settings) do
    settings
    |> Enum.group_by(fn {path, _prop, _val} -> path end)
    |> Enum.reduce(conn, fn {nodepath, props}, conn ->
      apply_setting_group(conn, nodepath, props)
    end)
  end

  defp apply_setting_group(%__MODULE__{error: e} = conn, _, _) when not is_nil(e), do: conn

  defp apply_setting_group(conn, nodepath, props) do
    conn =
      conn
      |> call(C.get_value_by_name(conn.ctx_oid, @config_provider_path), :qi)
      |> then(&call(&1, C.qi_settings_msf(&1.reply), :qi))
      |> then(&call(&1, C.create_config_update_access(nodepath), :interface))

    if conn.error do
      conn
    else
      update_oid = conn.reply

      conn
      |> call(C.qi_name_replace(update_oid), :qi)
      |> then(fn conn ->
        Enum.reduce(props, conn, fn {_path, name, value}, conn ->
          call(conn, C.replace_by_name(name, value), :void)
        end)
      end)
      |> call(C.qi_changes_batch(update_oid), :qi)
      |> call(C.commit_changes(), :void)
    end
  end

  @doc """
  Load a document from in-memory bytes via XInputStream.

  No shared filesystem needed — bytes are streamed over the URP socket.
  soffice calls `readBytes()` on our exported stream object.
  Stashes the document OID on `conn.doc_oid`.
  """
  @spec load_document_stream(t(), binary()) :: t()
  def load_document_stream(%__MODULE__{error: e} = conn, _bytes) when not is_nil(e), do: conn

  def load_document_stream(%__MODULE__{} = conn, bytes) when is_binary(bytes) do
    load_from_input_source(conn, bytes)
  end

  @doc """
  Load a document from a local file via XInputStream.

  Like `load_document_stream/2` but reads from a file on demand instead of
  holding the entire document in memory. The file must be accessible to the
  Elixir node (not soffice).
  Stashes the document OID on `conn.doc_oid`.
  """
  @spec load_document_file_stream(t(), Path.t()) :: t()
  def load_document_file_stream(%__MODULE__{error: e} = conn, _path) when not is_nil(e),
    do: conn

  def load_document_file_stream(%__MODULE__{} = conn, path) when is_binary(path) do
    with {:ok, %{size: size}} <- File.stat(path),
         {:ok, fd} <- File.open(path, [:read, :binary, :raw]) do
      conn = load_from_input_source(conn, {:file, fd, size})
      if conn.error, do: release_input(conn), else: conn
    else
      {:error, reason} ->
        %{conn | error: "#{path}: #{:file.format_error(reason)}"}
    end
  end

  @doc """
  Load a document from an enumerable via XInputStream.

  Like `load_document_stream/2` but pulls chunks lazily from any `Enumerable`
  (e.g. `File.stream!/2`, an S3 download stream). A demand-driven reader keeps
  at most the requested data buffered and feeds soffice on demand.
  Stashes the document OID on `conn.doc_oid`.
  """
  @spec load_document_enum_stream(t(), Enumerable.t()) :: t()
  def load_document_enum_stream(%__MODULE__{error: e} = conn, _enumerable)
      when not is_nil(e),
      do: conn

  def load_document_enum_stream(%__MODULE__{} = conn, enumerable) do
    reader = URP.Stream.start_enum_reader(enumerable)
    conn = load_from_input_source(conn, {:enum, <<>>, reader, conn.recv_timeout})
    if conn.error, do: release_input(conn), else: conn
  end

  @doc """
  Load a document by writing bytes to soffice's filesystem via XSimpleFileAccess.

  Instead of streaming bytes through XInputStream (which causes thousands of
  tiny read/seek round-trips), this writes the entire document to a temp file
  on soffice's filesystem and loads from a `file://` URL.

  Stashes the document OID on `conn.doc_oid` and the temp file URL on
  `conn.cleanup_url`. The caller should delete the temp file after conversion
  via `delete_file/2`.
  """
  @spec load_document_write(t(), binary()) :: t()
  def load_document_write(%__MODULE__{error: e} = conn, _bytes) when not is_nil(e), do: conn

  def load_document_write(%__MODULE__{} = conn, bytes) when is_binary(bytes) do
    conn = seed_protocol_caches(conn)
    conn = ensure_sfa(conn)
    url = temp_url("urp_in")

    conn
    |> call(C.sfa_open_file_write(conn.sfa_oid, url), :interface)
    |> call_reply(&C.qi_sfa_output/1, :qi)
    |> call(C.write_bytes(bytes), :void)
    |> call(C.close_output(), :void)
    |> load_document(url)
    |> then(&%{&1 | cleanup_url: url})
  end

  @doc "Delete a temp file on soffice's filesystem via XSimpleFileAccess.kill()."
  @spec delete_file(t(), String.t()) :: t()
  def delete_file(%__MODULE__{error: e} = conn, _url) when not is_nil(e), do: conn

  def delete_file(%__MODULE__{sfa_oid: sfa_oid} = conn, url) when is_binary(sfa_oid) do
    call(conn, C.sfa_kill(sfa_oid, url), :void)
  end

  defp delete_file_preserving_error(conn, url) do
    reply = conn.reply
    conn = attempt_cleanup(conn, &delete_file(&1, url))
    %{conn | reply: reply}
  end

  @doc """
  Store a document to soffice's filesystem and read back the result.

  Uses `store_to_url/4` to write the converted output to a temp file on
  soffice's filesystem, then reads it back in one shot via `read_file/2`.
  Replaces hundreds of round-trips with ~6. Stashes the output bytes in
  `conn.reply`.
  """
  @spec store_document_write(t(), keyword()) :: t()
  def store_document_write(%__MODULE__{error: e} = conn, _opts) when not is_nil(e), do: conn

  def store_document_write(%__MODULE__{doc_oid: doc_oid} = conn, opts) when is_binary(doc_oid) do
    filter = Keyword.fetch!(opts, :filter)
    filter_data = Keyword.get(opts, :filter_data, [])
    url = temp_url("urp_out")

    conn =
      conn
      |> store_to_url(url, filter, filter_data)
      |> read_file(url)

    delete_file_preserving_error(conn, url)
  end

  @doc """
  Read a file from soffice's filesystem via XSimpleFileAccess.

  Opens the file, reads all bytes in one frame, closes the stream.
  Stashes the file contents in `conn.reply`.
  """
  @spec read_file(t(), String.t()) :: t()
  def read_file(%__MODULE__{error: e} = conn, _url) when not is_nil(e), do: conn

  def read_file(%__MODULE__{} = conn, url) do
    conn = ensure_sfa(conn)

    conn =
      conn
      |> call(C.sfa_open_file_read(conn.sfa_oid, url), :interface)
      |> call_reply(&C.qi_sfa_input/1, :qi)
      |> call(C.available(), :int32)
      |> call_reply(&C.read_bytes/1, :read_bytes)

    if conn.error do
      conn
    else
      bytes = conn.reply
      %{call(conn, C.close_input(), :void) | reply: bytes}
    end
  end

  defp load_from_input_source(conn, source) do
    conn = seed_protocol_caches(conn)
    stream_oid = "elixir-in-#{:erlang.unique_integer([:positive])}"
    conn = %{conn | input_ctx: %{source: source, seekable_cache: nil, input_cache: nil}}

    conn =
      conn
      |> call(C.qi_loader(conn.desktop_oid), :qi)
      |> send_frame(
        C.load_component_from_url("private:stream", [
          C.hidden_property(),
          C.input_stream_property(stream_oid)
        ])
      )

    if conn.error do
      conn
    else
      # soffice will call readBytes/available/closeInput/seek/getPosition/getLength on our stream
      try do
        {reply, conn} = URP.Stream.recv_handling_input(conn, source, stream_oid)

        case P.parse_interface_reply(reply) do
          {:ok, doc_oid} -> %{conn | doc_oid: doc_oid}
          {:error, message} -> %{conn | error: message}
        end
      rescue
        e in URP.SocketError -> %{conn | error: e.reason}
        error -> %{conn | error: "input stream failed: #{Exception.message(error)}"}
      end
    end
  end

  @doc """
  Store a document via XOutputStream.

  No shared filesystem needed — output bytes are streamed back over the URP socket.
  soffice calls `writeBytes()` on our exported stream object.

  Stashes the result in `conn.reply`:

    * no sink (default) — `conn.reply` is the accumulated output bytes
    * `sink: {:path, path}` — writes to file, `conn.reply` is `:ok`
    * `sink: fun/1` — calls with each chunk, `conn.reply` is `:ok`
  """
  @spec store_to_stream(t(), keyword()) :: t()
  def store_to_stream(conn, opts \\ [])

  def store_to_stream(%__MODULE__{error: e} = conn, _opts) when not is_nil(e), do: conn

  def store_to_stream(%__MODULE__{doc_oid: doc_oid} = conn, opts)
      when is_binary(doc_oid) do
    filter = Keyword.fetch!(opts, :filter)
    filter_data = Keyword.get(opts, :filter_data, [])
    sink = Keyword.get(opts, :sink)

    stream_oid = "elixir-out-#{:erlang.unique_integer([:positive])}"

    props = store_props(filter, filter_data, [C.output_stream_property(stream_oid)])

    conn =
      conn
      |> call(C.qi_storable(doc_oid), :qi)
      |> send_frame(C.store_to_url("private:stream", props))

    if conn.error do
      conn
    else
      try do
        {reply, result, conn} = URP.Stream.recv_handling_output(conn, sink)

        case {P.parse_exception(reply), result} do
          {message, _result} when is_binary(message) ->
            remove_partial_sink(sink)
            %{conn | error: message, reply: nil}

          {nil, {:error, message}} ->
            remove_partial_sink(sink)
            %{conn | error: message, reply: nil}

          {nil, result} ->
            %{conn | reply: result}
        end
      rescue
        e in URP.SocketError ->
          remove_partial_sink(sink)
          %{conn | error: e.reason, reply: nil}

        error ->
          remove_partial_sink(sink)
          %{conn | error: "output stream failed: #{Exception.message(error)}", reply: nil}
      end
    end
  end

  ## SimpleFileAccess — lazily created for write-based document loading

  defp ensure_sfa(%__MODULE__{sfa_oid: oid} = conn) when is_binary(oid), do: conn

  defp ensure_sfa(%__MODULE__{} = conn) do
    conn =
      call(
        conn,
        C.create_instance_with_context(conn.smgr_oid, "com.sun.star.ucb.SimpleFileAccess"),
        :interface
      )

    conn
    |> stash(:sfa_oid)
    |> call_reply(&C.qi_sfa/1, :qi)
  end

  ## Handshake

  # Both sides send requestChange simultaneously. We use the minimum signed
  # int32 nonce to guarantee we lose, letting soffice drive commitChange.
  defp handshake!(%__MODULE__{sock: sock} = conn) do
    P.recv_frame(sock)

    P.send_frame(sock, C.request_change())

    # requestChange reply: we lost the nonce negotiation (expected)
    <<@reply_byte, 0::32>> = P.recv_frame(sock)
    P.send_frame(sock, P.reply(<<1::32-signed>>))
    P.recv_frame(sock)
    P.send_frame(sock, P.reply())

    conn
  end

  ## Bootstrap — ComponentContext → ServiceManager → Desktop

  defp bootstrap(conn) do
    tid = :crypto.strong_rand_bytes(20)

    conn = call(conn, C.qi_initial(tid), :qi)
    conn = %{conn | ctx_oid: conn.reply}
    conn = call(conn, C.qi_component_ctx(conn.ctx_oid), :qi)
    conn = call(conn, C.get_service_manager(), :interface)
    conn = %{conn | smgr_oid: conn.reply}
    conn = call(conn, C.create_desktop(conn.smgr_oid), :interface)
    %{conn | desktop_oid: conn.reply}
  end

  ## Property list helpers

  defp store_props(filter, filter_data, extra \\ []) do
    props = [C.filter_name_property(filter)]
    props = if filter_data != [], do: props ++ [C.filter_data_property(filter_data)], else: props
    props ++ extra
  end

  defp temp_url(prefix) do
    id = :crypto.strong_rand_bytes(18) |> Base.url_encode64(padding: false)
    "file:///tmp/#{prefix}_#{id}"
  end

  defp remove_partial_sink({:path, path}) do
    File.rm(path)
    :ok
  end

  defp remove_partial_sink(_sink), do: :ok

  ## Send + receive + parse

  defp call(%__MODULE__{} = conn, frame) do
    conn
    |> send_frame(frame)
    |> recv_reply()
  end

  defp call(%__MODULE__{error: e} = conn, _frame, _parser) when not is_nil(e), do: conn

  defp call(%__MODULE__{} = conn, frame, parser) do
    conn
    |> call(frame)
    |> parse_reply(parser)
  end

  defp call_reply(%__MODULE__{error: e} = conn, _builder, _parser) when not is_nil(e), do: conn

  defp call_reply(%__MODULE__{} = conn, builder, parser),
    do: call(conn, builder.(conn.reply), parser)

  defp parse_reply(%__MODULE__{error: e} = conn, _parser) when not is_nil(e), do: conn
  defp parse_reply(conn, :qi), do: parse_safely(conn, :qi, &P.parse_qi_reply/1)

  defp parse_reply(conn, :interface),
    do: parse_safely(conn, :interface, &P.parse_interface_reply/1)

  defp parse_reply(conn, :string),
    do: parse_safely(conn, :string, &P.parse_any_string_reply/1)

  defp parse_reply(conn, :strings),
    do: parse_safely(conn, :strings, &P.parse_string_sequence_reply/1)

  defp parse_reply(conn, :int32), do: parse_safely(conn, :int32, &P.parse_int32_reply/1)

  defp parse_reply(conn, :read_bytes),
    do: parse_safely(conn, :read_bytes, &P.parse_read_bytes_reply/1)

  defp parse_reply(conn, :void) do
    try do
      case P.parse_exception(conn.reply) do
        nil -> conn
        message -> %{conn | error: message, reply: nil}
      end
    rescue
      error ->
        %{conn | error: "malformed URP void reply: #{Exception.message(error)}", reply: nil}
    end
  end

  defp parse_safely(conn, parser, fun) do
    handle_parsed(conn, fun.(conn.reply))
  rescue
    error ->
      %{conn | error: "malformed URP #{parser} reply: #{Exception.message(error)}", reply: nil}
  end

  defp handle_parsed(conn, {:ok, value}), do: %{conn | reply: value}
  defp handle_parsed(conn, {:error, msg}), do: %{conn | error: msg, reply: nil}

  defp send_frame(%__MODULE__{error: e} = conn, _frame) when not is_nil(e), do: conn

  defp send_frame(%__MODULE__{} = conn, frame) do
    P.send_frame(conn.sock, frame)
    conn
  rescue
    e in URP.SocketError -> %{conn | error: e.reason}
    e -> %{conn | error: Exception.message(e)}
  end

  defp recv_reply(%__MODULE__{error: e} = conn) when not is_nil(e), do: conn

  defp recv_reply(%__MODULE__{} = conn) do
    payload = P.recv_frame(conn.sock, conn.recv_timeout, conn.max_frame_size)

    if P.is_reply?(payload) do
      %{conn | reply: payload}
    else
      case URP.Stream.try_handle_input(conn, payload) do
        {:handled, conn} ->
          recv_reply(conn)

        :not_input ->
          %{func_id: func_id, tid: new_tid} = P.parse_request(payload)
          conn = if new_tid, do: %{conn | reply_tid: new_tid}, else: conn

          if not P.one_way?(func_id),
            do: P.send_frame(conn.sock, URP.Stream.inject_tid(P.reply(), conn.reply_tid))

          recv_reply(conn)
      end
    end
  rescue
    e in URP.SocketError -> %{conn | error: e.reason}
    e -> %{conn | error: Exception.message(e)}
  end

  # Protocol parsing uses process-local read caches. Pool checkout scopes these
  # values to one connection and persists the updated maps back onto the worker.
  defp capture_protocol_caches(conn) do
    %{
      conn
      | tid_cache: Process.get(:urp_tid_cache, conn.tid_cache),
        oid_cache: Process.get(:urp_oid_cache, conn.oid_cache)
    }
  end

  defp seed_protocol_caches(%__MODULE__{} = conn) do
    if is_nil(Process.get(:urp_tid_cache)), do: Process.put(:urp_tid_cache, conn.tid_cache)
    if is_nil(Process.get(:urp_oid_cache)), do: Process.put(:urp_oid_cache, conn.oid_cache)
    conn
  end

  defp stash(%__MODULE__{error: e} = conn, _field) when not is_nil(e), do: conn
  defp stash(conn, field), do: Map.put(conn, field, conn.reply)

  defp stash_private(%__MODULE__{error: e} = conn, _key) when not is_nil(e), do: conn

  defp stash_private(%__MODULE__{private: private} = conn, key) do
    %{conn | private: Map.put(private, key, conn.reply)}
  end
end

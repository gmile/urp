defmodule URP.Bridge do
  @moduledoc """
  Mid-level UNO operations over a URP connection.

  Manages a TCP connection to a `soffice` process and provides functions for
  the UNO operations needed for document conversion: loading documents,
  storing to URL, and closing.

  Each connection performs a handshake and bootstraps a Desktop reference
  on `open!/2`. A connection handles one conversion at a time (soffice is
  single-threaded). Close the connection with `close!/1` when done.

  All functions take and return `conn`, following the Plug pattern. Document
  OIDs and conversion state are stashed on the conn struct — no separate
  values to track.

  ## Example

      conn = URP.Bridge.open!("localhost", 2002)
      conn = URP.Bridge.load_document!(conn, "file:///tmp/input.docx")
      conn = URP.Bridge.store_to_url!(conn, "file:///tmp/output.pdf", "writer_pdf_Export")
      conn = URP.Bridge.close_document!(conn)
      URP.Bridge.close!(conn)

  ## Streaming

  `load_document_stream!/2` and `store_to_stream!/2` use UNO's
  `XInputStream`/`XOutputStream` interfaces to transfer document bytes
  over the URP socket, eliminating the need for a shared filesystem.

      conn = URP.Bridge.open!("localhost", 2002)
      conn = URP.Bridge.load_document_stream!(conn, File.read!("input.docx"))
      {pdf, conn} = URP.Bridge.store_to_stream!(conn, filter: "writer_pdf_Export")
      URP.Bridge.close!(conn)

  ## Private storage

  Diagnostic functions stash results in `conn.private`:

      conn = URP.Bridge.version!(conn)
      conn.private.version
      # => "25.8.1.1"
  """

  alias URP.Protocol, as: P

  # sock is a plain :gen_tcp socket — inspect at any time via:
  #   :inet.getstat(conn.sock)   # send/recv counts, bytes, pending
  #   :inet.peername(conn.sock)  # remote {ip, port}
  @type t :: %__MODULE__{
          sock: :gen_tcp.socket(),
          desktop_oid: String.t(),
          ctx_oid: String.t(),
          smgr_oid: String.t(),
          doc_oid: String.t() | nil,
          cleanup_url: String.t() | nil,
          sfa_oid: String.t() | nil,
          input_ctx: map() | nil,
          reply_tid: binary() | nil,
          reader_type: non_neg_integer() | nil,
          last_reply: binary() | nil,
          last_error: String.t() | nil,
          tid_cache: map(),
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
    :last_reply,
    :last_error,
    tid_cache: %{},
    private: %{}
  ]

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

  # XMultiComponentFactory: createInstanceWithContext=3, getAvailableServiceNames=5
  @func_mcf_create_with_context 3
  @func_mcf_get_avail_services 5

  # XStorable2: storeToURL=8 (XInterface 0-2, XStorable 3-7, storeToURL 8)
  @func_storable_store_to_url 8

  # XCloseable: close=5 (XInterface 0-2, XCloseBroadcaster 3-4, close 5)
  @func_closeable_close 5

  # XMultiServiceFactory: createInstanceWithArguments=4
  @func_msf_create_with_args 4

  # XNameAccess (XInterface 0-2, XElementAccess 3-4, getByName 5, getElementNames 6)
  @func_na_get_by_name 5
  @func_na_get_element_names 6

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
  #  22  | XNameAccess                        | FilterFactory QI body
  #  23  | XNameAccess                        | FilterFactory getElementNames header
  #  24  | XNameAccess                        | TypeDetection QI body
  #  25  | XNameAccess                        | TypeDetection getElementNames header
  #  26  | XMultiServiceFactory               | locale config QI body
  #  27  | XMultiServiceFactory               | locale createInstanceWithArgs header
  #  28  | XNameAccess                        | locale config QI body
  #  29  | XNameAccess                        | locale getByName header

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
  @type_new_ff_name_access {:new, @xi_name_access, 23}
  @type_new_td_name_access {:new, @xi_name_access, 25}
  @type_new_locale_msf {:new, @xi_multi_service_factory, 27}
  @type_new_locale_na {:new, @xi_name_access, 29}

  # Type cache indices for queryInterface body registration (see cache table above).
  # QI bodies and request headers each get their own slot, even for the same interface.
  @qi_cache_component_ctx 2
  @qi_cache_loader 5
  @qi_cache_storable 7
  @qi_cache_closeable 9
  @qi_cache_msf 12
  @qi_cache_name_access 15
  @qi_cache_sfa 19
  @qi_cache_sfa_output 20
  @qi_cache_sfa_input 21
  @qi_cache_ff_name_access 22
  @qi_cache_td_name_access 24
  @qi_cache_locale_msf 26
  @qi_cache_locale_na 28

  # Inline type cache indices for property value encoding (not request headers)
  @cache_export_input 10
  @cache_export_output 11
  @cache_named_value 14
  @cache_filter_data_seq 18

  # Well-known OIDs and TIDs used during handshake and bootstrap
  @oid_protocol_props "UrpProtocolProperties"
  @tid_protocol_props ".UrpProtocolPropertiesTid"
  @oid_component_context "StarOffice.ComponentContext"

  # OID/TID cache indices — sequential allocation for identity references.
  # Index 0 is allocated during handshake, index 1 during bootstrap.
  @cache_handshake 0
  @cache_bootstrap 1
  @oid_ctx 2
  @oid_smgr 3
  @oid_desktop 4
  @oid_doc_storable 5
  @oid_doc_closeable 6
  @oid_config_provider 7
  @oid_config_access 8
  @oid_sfa 9
  @oid_export_input 10
  @oid_export_output 11
  @oid_sfa_os 12
  @oid_sfa_is 13
  @oid_filter_factory 14
  @oid_type_detection 15
  @oid_locale_config 16

  # createInstanceWithContext body suffix: null OID + component context cache
  @ctx_ref <<0x00, @oid_ctx::16>>

  # Reply marker byte — integer form of P.reply() for use in pattern matching
  @reply_byte 0x80

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

  # loadComponentFromURL fixed parameters
  @frame_search_default <<0::32>>

  # Pre-built static frame bodies — no runtime values, computed at compile time.

  @handshake_request_change P.request(@func_request_change,
                              type: @type_new_protocol_props,
                              oid: {@oid_protocol_props, @cache_handshake},
                              tid: {@tid_protocol_props, @cache_handshake}
                            ) <> @losing_nonce

  @get_service_manager P.request(@func_ctx_get_service_manager,
                         type: @type_new_component_ctx
                       ) <> P.null_ctx()

  @close_document P.request(@func_closeable_close,
                    type: @type_closeable
                  ) <> P.null_ctx() <> <<1>>

  @close_output P.request(@func_os_close_output) <> P.null_ctx()

  @close_input P.request(@func_is_close_input) <> P.null_ctx()

  @read_all_bytes P.request(@func_is_read_bytes,
                    type: @type_is_sfa
                  ) <> P.null_ctx() <> <<@max_read_bytes::32-signed>>

  @get_version P.request(@func_na_get_by_name,
                 type: @type_new_name_access
               ) <> P.null_ctx() <> P.enc_str("ooSetupVersionAboutBox")

  @create_config_access P.request(@func_msf_create_with_args, type: @type_new_msf) <>
                          P.null_ctx() <>
                          P.enc_str("com.sun.star.configuration.ConfigurationAccess") <>
                          <<1>> <>
                          <<@tc_struct ||| @tc_new, @cache_named_value::16>> <>
                          P.enc_str("com.sun.star.beans.NamedValue") <>
                          P.enc_str("nodepath") <>
                          <<@tc_string>> <>
                          P.enc_str("/org.openoffice.Setup/Product")

  @create_locale_config_access P.request(@func_msf_create_with_args, type: @type_new_locale_msf) <>
                                 P.null_ctx() <>
                                 P.enc_str("com.sun.star.configuration.ConfigurationAccess") <>
                                 <<1>> <>
                                 <<@tc_struct ||| @tc_new, @cache_named_value::16>> <>
                                 P.enc_str("com.sun.star.beans.NamedValue") <>
                                 P.enc_str("nodepath") <>
                                 <<@tc_string>> <>
                                 P.enc_str("/org.openoffice.Setup/L10N")

  @get_locale P.request(@func_na_get_by_name,
                type: @type_new_locale_na
              ) <> P.null_ctx() <> P.enc_str("ooLocale")

  # Pre-built request prefixes — static header + null context, dynamic args appended at runtime.

  @load_url_prefix P.request(@func_loader_load, type: @type_new_loader) <> P.null_ctx()

  @store_to_url_prefix P.request(@func_storable_store_to_url, type: @type_new_storable) <>
                         P.null_ctx()

  @write_bytes_prefix P.request(@func_os_write_bytes, type: @type_os_sfa) <> P.null_ctx()

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
  Load a document from a `file://` URL. Stashes the document OID on `conn.doc_oid`.

  Raises if soffice cannot open the file.
  """
  @spec load_document!(t(), String.t()) :: t()
  def load_document!(%__MODULE__{sock: sock} = conn, url) do
    qi!(
      conn,
      P.request(@func_query_interface,
        type: @type_interface,
        oid: {conn.desktop_oid, @oid_desktop}
      ),
      P.type_new(@xi_component_loader, @qi_cache_loader)
    )

    # loadComponentFromURL(url, "_blank", 0, [Hidden=true])
    hidden_prop = P.property("Hidden", @tc_boolean, <<1>>)

    reply =
      call!(
        sock,
        @load_url_prefix <>
          P.enc_str(url) <>
          P.enc_str("_blank") <>
          @frame_search_default <>
          <<1>> <>
          hidden_prop
      )

    doc_oid =
      P.parse_interface_reply(reply) ||
        raise "loadComponentFromURL failed: #{P.parse_exception(reply)}"

    %{conn | doc_oid: doc_oid}
  end

  @doc """
  Store a document to a `file://` URL with the given [export filter](https://help.libreoffice.org/latest/en-US/text/shared/guide/convertfilters.html).

  Common filters: `"writer_pdf_Export"`, `"calc_pdf_Export"`, `"impress_pdf_Export"`.

  `filter_data` is an optional keyword list of export-specific options passed
  as a nested `FilterData` property (e.g. `[UseLosslessCompression: true]`).
  """
  @spec store_to_url!(t(), String.t(), String.t(), keyword()) :: t()
  def store_to_url!(%__MODULE__{doc_oid: doc_oid} = conn, url, filter, filter_data \\ [])
      when is_binary(doc_oid) do
    conn =
      qi(
        conn,
        P.request(@func_query_interface,
          type: @type_interface,
          oid: {doc_oid, @oid_doc_storable}
        ),
        P.type_new(@xi_storable2, @qi_cache_storable)
      )

    filter_name_prop = P.property("FilterName", @tc_string, P.enc_str(filter))
    filter_data_prop = encode_filter_data(filter_data)
    props = [filter_name_prop, filter_data_prop]
    prop_count = Enum.count(props, &(&1 != <<>>))

    conn =
      call(
        conn,
        @store_to_url_prefix <>
          P.enc_str(url) <>
          <<prop_count>> <>
          IO.iodata_to_binary(props)
      )

    if conn.last_reply != P.reply() do
      raise "storeToURL failed: #{P.parse_exception(conn.last_reply)}"
    end

    conn
  end

  @doc "Close the loaded document, releasing soffice resources."
  @spec close_document!(t()) :: t()
  def close_document!(%__MODULE__{doc_oid: doc_oid} = conn) when is_binary(doc_oid) do
    conn =
      conn
      |> qi(
        P.request(@func_query_interface,
          type: @type_interface,
          oid: {doc_oid, @oid_doc_closeable}
        ),
        P.type_new(@xi_closeable, @qi_cache_closeable)
      )
      |> call(@close_document)

    %{conn | doc_oid: nil}
  end

  @doc """
  Query the soffice version string over URP.

  Reads `ooSetupVersionAboutBox` from the configuration API via 5 UNO
  round trips. Stashes the result in `conn.private.version`.
  """
  @spec version!(t()) :: t()
  def version!(%__MODULE__{sock: sock} = conn) do
    # Resolve the configuration provider singleton
    reply =
      call!(
        sock,
        P.request(@func_ctx_get_value_by_name,
          type: @type_component_ctx,
          oid: {conn.ctx_oid, @oid_ctx}
        ) <>
          P.null_ctx() <>
          P.enc_str("/singletons/com.sun.star.configuration.theDefaultProvider")
      )

    config_provider_oid =
      P.parse_qi_reply(reply) ||
        raise "getValueByName(theDefaultProvider) failed: #{P.parse_exception(reply)}"

    qi!(
      conn,
      P.request(@func_query_interface,
        type: @type_interface,
        oid: {config_provider_oid, @oid_config_provider}
      ),
      P.type_new(@xi_multi_service_factory, @qi_cache_msf)
    )

    # Open /org.openoffice.Setup/Product via ConfigurationAccess
    reply = call!(sock, @create_config_access)

    config_access_oid =
      P.parse_interface_reply(reply) ||
        raise "createInstanceWithArguments(ConfigurationAccess) failed: #{P.parse_exception(reply)}"

    qi!(
      conn,
      P.request(@func_query_interface,
        type: @type_interface,
        oid: {config_access_oid, @oid_config_access}
      ),
      P.type_new(@xi_name_access, @qi_cache_name_access)
    )

    reply = call!(sock, @get_version)

    version =
      P.parse_any_string_reply(reply) ||
        raise "getByName(ooSetupVersionAboutBox) failed: #{P.parse_exception(reply)}"

    put_private(conn, :version, version)
  end

  @doc """
  List all service names registered in the UNO service manager.

  Calls `XMultiComponentFactory.getAvailableServiceNames()`.
  Stashes the result in `conn.private.services`.
  """
  @spec services!(t()) :: t()
  def services!(%__MODULE__{sock: sock} = conn) do
    reply =
      call!(
        sock,
        P.request(@func_mcf_get_avail_services,
          type: @type_multi_comp_fac,
          oid: {conn.smgr_oid, @oid_smgr}
        ) <> P.null_ctx()
      )

    services =
      P.parse_string_sequence_reply(reply) ||
        raise "getAvailableServiceNames failed: #{P.parse_exception(reply)}"

    put_private(conn, :services, services)
  end

  @doc """
  List all export filter names registered in soffice.

  Creates a `FilterFactory` instance and calls `getElementNames()` via `XNameAccess`.
  Stashes the result in `conn.private.filters`.
  """
  @spec filters!(t()) :: t()
  def filters!(%__MODULE__{sock: sock} = conn) do
    # 1. Create FilterFactory
    reply =
      call!(
        sock,
        P.request(@func_mcf_create_with_context,
          type: @type_multi_comp_fac,
          oid: {conn.smgr_oid, @oid_smgr}
        ) <>
          P.null_ctx() <>
          P.enc_str("com.sun.star.document.FilterFactory") <> @ctx_ref
      )

    ff_oid =
      P.parse_interface_reply(reply) ||
        raise "createInstanceWithContext(FilterFactory) failed: #{P.parse_exception(reply)}"

    # 2. QI to XNameAccess
    qi!(
      conn,
      P.request(@func_query_interface,
        type: @type_interface,
        oid: {ff_oid, @oid_filter_factory}
      ),
      P.type_new(@xi_name_access, @qi_cache_ff_name_access)
    )

    # 3. getElementNames()
    reply =
      call!(
        sock,
        P.request(@func_na_get_element_names,
          type: @type_new_ff_name_access
        ) <> P.null_ctx()
      )

    filters =
      P.parse_string_sequence_reply(reply) ||
        raise "getElementNames(FilterFactory) failed: #{P.parse_exception(reply)}"

    put_private(conn, :filters, filters)
  end

  @doc """
  List all document type names registered in soffice.

  Creates a `TypeDetection` instance and calls `getElementNames()` via `XNameAccess`.
  Stashes the result in `conn.private.types`.
  """
  @spec types!(t()) :: t()
  def types!(%__MODULE__{sock: sock} = conn) do
    # 1. Create TypeDetection
    reply =
      call!(
        sock,
        P.request(@func_mcf_create_with_context,
          type: @type_multi_comp_fac,
          oid: {conn.smgr_oid, @oid_smgr}
        ) <>
          P.null_ctx() <>
          P.enc_str("com.sun.star.document.TypeDetection") <> @ctx_ref
      )

    td_oid =
      P.parse_interface_reply(reply) ||
        raise "createInstanceWithContext(TypeDetection) failed: #{P.parse_exception(reply)}"

    # 2. QI to XNameAccess
    qi!(
      conn,
      P.request(@func_query_interface,
        type: @type_interface,
        oid: {td_oid, @oid_type_detection}
      ),
      P.type_new(@xi_name_access, @qi_cache_td_name_access)
    )

    # 3. getElementNames()
    reply =
      call!(
        sock,
        P.request(@func_na_get_element_names,
          type: @type_new_td_name_access
        ) <> P.null_ctx()
      )

    types =
      P.parse_string_sequence_reply(reply) ||
        raise "getElementNames(TypeDetection) failed: #{P.parse_exception(reply)}"

    put_private(conn, :types, types)
  end

  @doc """
  Query the soffice locale string over URP.

  Reads `ooLocale` from `/org.openoffice.Setup/L10N` via the configuration API.
  Stashes the result in `conn.private.locale`.
  """
  @spec locale!(t()) :: t()
  def locale!(%__MODULE__{sock: sock} = conn) do
    # 1. Resolve the configuration provider singleton
    reply =
      call!(
        sock,
        P.request(@func_ctx_get_value_by_name,
          type: @type_component_ctx,
          oid: {conn.ctx_oid, @oid_ctx}
        ) <>
          P.null_ctx() <>
          P.enc_str("/singletons/com.sun.star.configuration.theDefaultProvider")
      )

    config_provider_oid =
      P.parse_qi_reply(reply) ||
        raise "getValueByName(theDefaultProvider) failed: #{P.parse_exception(reply)}"

    # 2. QI to XMultiServiceFactory
    qi!(
      conn,
      P.request(@func_query_interface,
        type: @type_interface,
        oid: {config_provider_oid, @oid_config_provider}
      ),
      P.type_new(@xi_multi_service_factory, @qi_cache_locale_msf)
    )

    # 3. Open /org.openoffice.Setup/L10N via ConfigurationAccess
    reply = call!(sock, @create_locale_config_access)

    config_access_oid =
      P.parse_interface_reply(reply) ||
        raise "createInstanceWithArguments(ConfigurationAccess/L10N) failed: #{P.parse_exception(reply)}"

    # 4. QI to XNameAccess
    qi!(
      conn,
      P.request(@func_query_interface,
        type: @type_interface,
        oid: {config_access_oid, @oid_locale_config}
      ),
      P.type_new(@xi_name_access, @qi_cache_locale_na)
    )

    # 5. getByName("ooLocale")
    reply = call!(sock, @get_locale)

    locale =
      P.parse_any_string_reply(reply) ||
        raise "getByName(ooLocale) failed: #{P.parse_exception(reply)}"

    put_private(conn, :locale, locale)
  end

  @doc """
  Load a document from in-memory bytes via XInputStream.

  No shared filesystem needed — bytes are streamed over the URP socket.
  soffice calls `readBytes()` on our exported stream object.
  Stashes the document OID on `conn.doc_oid`.
  """
  @spec load_document_stream!(t(), binary()) :: t()
  def load_document_stream!(%__MODULE__{} = conn, bytes) when is_binary(bytes) do
    load_from_input_source!(conn, bytes)
  end

  @doc """
  Load a document from a local file via XInputStream.

  Like `load_document_stream!/2` but reads from a file on demand instead of
  holding the entire document in memory. The file must be accessible to the
  Elixir node (not soffice).
  Stashes the document OID on `conn.doc_oid`.
  """
  @spec load_document_file_stream!(t(), Path.t()) :: t()
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
  Stashes the document OID on `conn.doc_oid`.
  """
  @spec load_document_enum_stream!(t(), Enumerable.t()) :: t()
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

  Stashes the document OID on `conn.doc_oid` and the temp file URL on
  `conn.cleanup_url`. The caller should delete the temp file after conversion
  via `delete_file!/2`.
  """
  @spec load_document_write!(t(), binary()) :: t()
  def load_document_write!(%__MODULE__{} = conn, bytes) when is_binary(bytes) do
    conn = seed_tid_cache(conn)
    {sfa_oid, conn} = ensure_sfa!(conn)
    id = :erlang.unique_integer([:positive])
    url = "file:///tmp/urp_in_#{id}"

    conn = sfa_call(conn, sfa_oid, @func_sfa_open_file_write, P.enc_str(url))
    os_oid = P.parse_interface_reply(conn.last_reply) || raise "openFileWrite failed"

    conn =
      conn
      |> qi(
        P.request(@func_query_interface, type: @type_interface, oid: {os_oid, @oid_sfa_os}),
        P.type_new(@xi_output_stream, @qi_cache_sfa_output)
      )
      |> call(@write_bytes_prefix <> P.enc_str(bytes))
      |> call(@close_output)
      |> load_document!(url)

    %{conn | cleanup_url: url}
  end

  @doc "Delete a temp file on soffice's filesystem via XSimpleFileAccess.kill()."
  @spec delete_file!(t(), String.t()) :: t()
  def delete_file!(%__MODULE__{sfa_oid: sfa_oid} = conn, url) when is_binary(sfa_oid) do
    sfa_call(conn, sfa_oid, @func_sfa_kill, P.enc_str(url))
  end

  @doc """
  Store a document to soffice's filesystem and read back the result.

  Uses `store_to_url!` to write the converted output to a temp file on
  soffice's filesystem, then reads it back in one shot via `read_file!/2`.
  Replaces hundreds of round-trips with ~6. Reads `conn.doc_oid`.
  """
  @spec store_document_write!(t(), keyword()) :: {binary(), t()}
  def store_document_write!(%__MODULE__{doc_oid: doc_oid} = conn, opts) when is_binary(doc_oid) do
    filter = Keyword.fetch!(opts, :filter)
    filter_data = Keyword.get(opts, :filter_data, [])
    id = :erlang.unique_integer([:positive])
    url = "file:///tmp/urp_out_#{id}"

    conn = store_to_url!(conn, url, filter, filter_data)
    {bytes, conn} = read_file!(conn, url)
    conn = delete_file!(conn, url)

    {bytes, conn}
  end

  @doc """
  Read a file from soffice's filesystem via XSimpleFileAccess.

  Opens the file, reads all bytes in one frame, closes the stream.
  """
  @spec read_file!(t(), String.t()) :: {binary(), t()}
  def read_file!(%__MODULE__{} = conn, url) do
    {sfa_oid, conn} = ensure_sfa!(conn)

    conn = sfa_call(conn, sfa_oid, @func_sfa_open_file_read, P.enc_str(url))
    is_oid = P.parse_interface_reply(conn.last_reply) || raise "openFileRead failed"

    conn =
      qi(
        conn,
        P.request(@func_query_interface, type: @type_interface, oid: {is_oid, @oid_sfa_is}),
        P.type_new(@xi_input_stream, @qi_cache_sfa_input)
      )

    conn = call(conn, @read_all_bytes)
    bytes = P.parse_read_bytes_reply(conn.last_reply)
    conn = call(conn, @close_input)

    {bytes, conn}
  end

  defp load_from_input_source!(conn, source) do
    conn = seed_tid_cache(conn)
    stream_oid = "elixir-in-#{:erlang.unique_integer([:positive])}"

    qi!(
      conn,
      P.request(@func_query_interface,
        type: @type_interface,
        oid: {conn.desktop_oid, @oid_desktop}
      ),
      P.type_new(@xi_component_loader, @qi_cache_loader)
    )

    # loadComponentFromURL("private:stream", "_blank", 0, [Hidden, InputStream])
    hidden_prop = P.property("Hidden", @tc_boolean, <<1>>)

    input_stream_prop =
      P.property(
        "InputStream",
        @tc_interface ||| @tc_new,
        <<@cache_export_input::16>> <>
          P.enc_str(@xi_input_stream) <>
          P.enc_str(stream_oid) <> <<@oid_export_input::16>>
      )

    P.send_frame(
      conn.sock,
      @load_url_prefix <>
        P.enc_str("private:stream") <>
        P.enc_str("_blank") <>
        @frame_search_default <>
        <<2>> <>
        hidden_prop <>
        input_stream_prop
    )

    # soffice will call readBytes/available/closeInput/seek/getPosition/getLength on our stream
    {reply, conn} = URP.Stream.recv_handling_input(conn, source, stream_oid)

    doc_oid =
      P.parse_interface_reply(reply) ||
        raise "loadComponentFromURL(stream) failed: #{P.parse_exception(reply)}"

    %{conn | doc_oid: doc_oid}
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
  @spec store_to_stream!(t(), keyword()) :: {binary() | :ok, t()}
  def store_to_stream!(%__MODULE__{doc_oid: doc_oid} = conn, opts \\ [])
      when is_binary(doc_oid) do
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
      P.type_new(@xi_storable2, @qi_cache_storable)
    )

    filter_name_prop = P.property("FilterName", @tc_string, P.enc_str(filter))
    filter_data_prop = encode_filter_data(filter_data)

    output_stream_prop =
      P.property(
        "OutputStream",
        @tc_interface ||| @tc_new,
        <<@cache_export_output::16>> <>
          P.enc_str(@xi_output_stream) <>
          P.enc_str(stream_oid) <> <<@oid_export_output::16>>
      )

    props = [filter_name_prop, filter_data_prop, output_stream_prop]
    prop_count = Enum.count(props, &(&1 != <<>>))

    P.send_frame(
      conn.sock,
      @store_to_url_prefix <>
        P.enc_str("private:stream") <>
        <<prop_count>> <>
        IO.iodata_to_binary(props)
    )

    {_reply, result, conn} = URP.Stream.recv_handling_output(conn, sink)
    {result, conn}
  end

  ## SimpleFileAccess — lazily created for write-based document loading

  defp ensure_sfa!(%__MODULE__{sfa_oid: oid} = conn) when is_binary(oid), do: {oid, conn}

  defp ensure_sfa!(%__MODULE__{} = conn) do
    conn =
      call(
        conn,
        P.request(@func_mcf_create_with_context,
          type: @type_multi_comp_fac,
          oid: {conn.smgr_oid, @oid_smgr}
        ) <>
          P.null_ctx() <>
          P.enc_str("com.sun.star.ucb.SimpleFileAccess") <>
          @ctx_ref
      )

    sfa_oid =
      P.parse_interface_reply(conn.last_reply) ||
        raise "createInstanceWithContext(SimpleFileAccess) failed"

    conn =
      qi(
        conn,
        P.request(@func_query_interface, type: @type_interface, oid: {sfa_oid, @oid_sfa}),
        P.type_new(@xi_simple_file_access, @qi_cache_sfa)
      )

    conn = %{conn | sfa_oid: sfa_oid}
    {sfa_oid, conn}
  end

  ## Handshake

  # Both sides send requestChange simultaneously. We use the minimum signed
  # int32 nonce to guarantee we lose, letting soffice drive commitChange.
  defp handshake!(%__MODULE__{sock: sock}) do
    P.recv_frame(sock)

    P.send_frame(sock, @handshake_request_change)

    # requestChange reply: we lost the nonce negotiation (expected)
    <<@reply_byte, 0::32>> = P.recv_frame(sock)
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
          oid: {@oid_component_context, @cache_bootstrap},
          tid: {tid, @cache_bootstrap}
        ),
        P.type_cached(@cache_bootstrap)
      )

    qi!(
      sock,
      P.request(@func_query_interface, oid: {ctx_oid, @oid_ctx}),
      P.type_new(@xi_component_ctx, @qi_cache_component_ctx)
    )

    P.send_frame(sock, @get_service_manager)
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
        @ctx_ref
    )

    desktop_oid = P.parse_interface_reply(P.recv_frame(sock))
    {ctx_oid, smgr_oid, desktop_oid}
  end

  ## queryInterface helpers

  # Bootstrap variant — uses raw socket, returns OID only.
  defp qi!(%__MODULE__{sock: sock}, header, body_type_param) do
    qi!(sock, header, body_type_param)
  end

  defp qi!(sock, header, body_type_param) do
    P.parse_qi_reply(call!(sock, header <> P.null_ctx() <> body_type_param))
  end

  # Conn-threading variant — returns conn (OID discarded).
  defp qi(%__MODULE__{} = conn, header, body_type_param) do
    call(conn, header <> P.null_ctx() <> body_type_param)
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
      <<@cache_filter_data_seq::16>> <>
        P.enc_str("[]com.sun.star.beans.PropertyValue") <>
        <<length(filter_data)>> <>
        inner
    )
  end

  defp encode_any_value(true), do: {@tc_boolean, <<1>>}
  defp encode_any_value(false), do: {@tc_boolean, <<0>>}
  defp encode_any_value(n) when is_integer(n), do: {@tc_long, <<n::32-signed>>}
  defp encode_any_value(s) when is_binary(s), do: {@tc_string, P.enc_str(s)}

  # Bootstrap runs in the pool worker process, but conversions run in the
  # checkout caller's process. Seed the TID cache so reply parsing works.
  defp seed_tid_cache(%__MODULE__{tid_cache: cache} = conn) when cache == %{}, do: conn

  defp seed_tid_cache(%__MODULE__{tid_cache: cache} = conn) do
    existing = Process.get(:urp_tid_cache, %{})
    Process.put(:urp_tid_cache, Map.merge(cache, existing))
    conn
  end

  ## Send + receive helpers

  # Bootstrap variants — no conn struct yet, use raw socket.
  defp call!(sock, frame) do
    P.send_frame(sock, frame)
    recv_reply!(sock)
  end

  defp recv_reply!(sock) do
    payload = P.recv_frame(sock)

    if P.is_reply?(payload) do
      payload
    else
      %{func_id: func_id, tid: new_tid} = P.parse_request(payload)

      if new_tid, do: Process.put(:urp_reply_tid, new_tid)
      tid = new_tid || Process.get(:urp_reply_tid)

      if not P.one_way?(func_id),
        do: P.send_frame(sock, URP.Stream.inject_tid(P.reply(), tid))

      recv_reply!(sock)
    end
  end

  # Conn-threading variants — used during conversion phases.
  # All return conn. recv_reply stashes the reply on conn.last_reply.

  defp send_frame(%__MODULE__{} = conn, frame) do
    P.send_frame(conn.sock, frame)
    conn
  end

  defp call(%__MODULE__{} = conn, frame) do
    conn
    |> send_frame(frame)
    |> recv_reply()
  end

  defp sfa_call(%__MODULE__{} = conn, sfa_oid, func, args) do
    call(conn, P.request(func, type: @type_sfa, oid: {sfa_oid, @oid_sfa}) <> P.null_ctx() <> args)
  end

  defp recv_reply(%__MODULE__{} = conn) do
    payload = P.recv_frame(conn.sock)

    if P.is_reply?(payload) do
      %{conn | last_reply: payload}
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
  end

  defp put_private(%__MODULE__{private: private} = conn, key, value) do
    %{conn | private: Map.put(private, key, value)}
  end
end

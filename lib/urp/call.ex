defmodule URP.Call do
  @moduledoc """
  Binary frame builders for UNO API calls.

  Each function constructs the wire-format payload for a specific UNO remote
  procedure call. `URP.Bridge` uses these builders instead of assembling
  binary payloads inline.

  The `qi_*` functions build complete queryInterface frames (header + null
  context + body type parameter).
  """

  alias URP.Protocol, as: P

  import Bitwise

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
  @func_loader_load 3
  @func_ctx_get_value_by_name 3
  @func_ctx_get_service_manager 4
  @func_mcf_create_with_context 3
  @func_mcf_get_avail_services 5
  @func_storable_store_to_url 8
  @func_closeable_close 5
  @func_msf_create_with_args 4
  @func_na_get_by_name 5
  @func_na_get_element_names 6
  @func_sfa_kill 5
  @func_sfa_open_file_read 15
  @func_sfa_open_file_write 16
  @func_is_read_bytes 3
  @func_is_close_input 7
  @func_os_write_bytes 3
  @func_os_close_output 5

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

  # Request header type tuples
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

  # QI body type cache indices
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

  # Inline type cache indices for property value encoding
  @cache_export_input 10
  @cache_export_output 11
  @cache_named_value 14
  @cache_filter_data_seq 18

  # Well-known OIDs and TIDs
  @oid_protocol_props "UrpProtocolProperties"
  @tid_protocol_props ".UrpProtocolPropertiesTid"
  @oid_component_context "StarOffice.ComponentContext"

  # OID/TID cache indices
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

  # loadComponentFromURL fixed parameters
  @frame_search_default <<0::32>>

  # Minimum signed int32 — guarantees we lose the nonce negotiation
  @losing_nonce <<-2_147_483_648::32-signed>>

  # UNO TypeClass values — include/typelib/typeclass.h
  @tc_boolean 2
  @tc_long 6
  @tc_string 12
  @tc_struct 17
  @tc_sequence 20
  @tc_interface 22
  @tc_new 0x80

  # Pre-built static frames (computed at compile time)

  @request_change_frame P.request(@func_request_change,
                          type: @type_new_protocol_props,
                          oid: {@oid_protocol_props, @cache_handshake},
                          tid: {@tid_protocol_props, @cache_handshake}
                        ) <> @losing_nonce

  @get_service_manager_frame P.request(@func_ctx_get_service_manager,
                               type: @type_new_component_ctx
                             ) <> P.null_ctx()

  @close_document_frame P.request(@func_closeable_close,
                          type: @type_closeable
                        ) <> P.null_ctx() <> <<1>>

  @close_output_frame P.request(@func_os_close_output) <> P.null_ctx()

  @close_input_frame P.request(@func_is_close_input) <> P.null_ctx()

  @read_all_bytes_frame P.request(@func_is_read_bytes,
                          type: @type_is_sfa
                        ) <> P.null_ctx() <> <<@max_read_bytes::32-signed>>

  @get_version_frame P.request(@func_na_get_by_name,
                       type: @type_new_name_access
                     ) <> P.null_ctx() <> P.enc_str("ooSetupVersionAboutBox")

  @create_config_access_frame P.request(@func_msf_create_with_args, type: @type_new_msf) <>
                                P.null_ctx() <>
                                P.enc_str("com.sun.star.configuration.ConfigurationAccess") <>
                                <<1>> <>
                                <<@tc_struct ||| @tc_new, @cache_named_value::16>> <>
                                P.enc_str("com.sun.star.beans.NamedValue") <>
                                P.enc_str("nodepath") <>
                                <<@tc_string>> <>
                                P.enc_str("/org.openoffice.Setup/Product")

  @create_locale_config_access_frame P.request(@func_msf_create_with_args,
                                       type: @type_new_locale_msf
                                     ) <>
                                       P.null_ctx() <>
                                       P.enc_str("com.sun.star.configuration.ConfigurationAccess") <>
                                       <<1>> <>
                                       <<@tc_struct ||| @tc_new, @cache_named_value::16>> <>
                                       P.enc_str("com.sun.star.beans.NamedValue") <>
                                       P.enc_str("nodepath") <>
                                       <<@tc_string>> <>
                                       P.enc_str("/org.openoffice.Setup/L10N")

  @get_locale_frame P.request(@func_na_get_by_name,
                      type: @type_new_locale_na
                    ) <> P.null_ctx() <> P.enc_str("ooLocale")

  @load_url_prefix P.request(@func_loader_load, type: @type_new_loader) <> P.null_ctx()

  @store_to_url_prefix P.request(@func_storable_store_to_url, type: @type_new_storable) <>
                         P.null_ctx()

  @write_bytes_prefix P.request(@func_os_write_bytes, type: @type_os_sfa) <> P.null_ctx()

  ## Handshake

  @doc false
  def request_change, do: @request_change_frame

  ## queryInterface frames

  @doc "Initial QI during bootstrap (registers XInterface type + TID)."
  def qi_initial(tid) do
    P.request(@func_query_interface,
      type: @type_new_interface,
      oid: {@oid_component_context, @cache_bootstrap},
      tid: {tid, @cache_bootstrap}
    ) <> P.null_ctx() <> P.type_cached(@cache_bootstrap)
  end

  @doc "QI for XComponentContext (bootstrap only — reuses type from previous message)."
  def qi_component_ctx(ctx_oid) do
    P.request(@func_query_interface, oid: {ctx_oid, @oid_ctx}) <>
      P.null_ctx() <> P.type_new(@xi_component_ctx, @qi_cache_component_ctx)
  end

  @doc false
  def qi_loader(desktop_oid) do
    P.request(@func_query_interface, type: @type_interface, oid: {desktop_oid, @oid_desktop}) <>
      P.null_ctx() <> P.type_new(@xi_component_loader, @qi_cache_loader)
  end

  @doc false
  def qi_storable(doc_oid) do
    P.request(@func_query_interface, type: @type_interface, oid: {doc_oid, @oid_doc_storable}) <>
      P.null_ctx() <> P.type_new(@xi_storable2, @qi_cache_storable)
  end

  @doc false
  def qi_closeable(doc_oid) do
    P.request(@func_query_interface, type: @type_interface, oid: {doc_oid, @oid_doc_closeable}) <>
      P.null_ctx() <> P.type_new(@xi_closeable, @qi_cache_closeable)
  end

  @doc false
  def qi_msf(config_provider_oid) do
    P.request(@func_query_interface,
      type: @type_interface,
      oid: {config_provider_oid, @oid_config_provider}
    ) <> P.null_ctx() <> P.type_new(@xi_multi_service_factory, @qi_cache_msf)
  end

  @doc false
  def qi_name_access(config_access_oid) do
    P.request(@func_query_interface,
      type: @type_interface,
      oid: {config_access_oid, @oid_config_access}
    ) <> P.null_ctx() <> P.type_new(@xi_name_access, @qi_cache_name_access)
  end

  @doc false
  def qi_ff_name_access(ff_oid) do
    P.request(@func_query_interface,
      type: @type_interface,
      oid: {ff_oid, @oid_filter_factory}
    ) <> P.null_ctx() <> P.type_new(@xi_name_access, @qi_cache_ff_name_access)
  end

  @doc false
  def qi_td_name_access(td_oid) do
    P.request(@func_query_interface,
      type: @type_interface,
      oid: {td_oid, @oid_type_detection}
    ) <> P.null_ctx() <> P.type_new(@xi_name_access, @qi_cache_td_name_access)
  end

  @doc false
  def qi_locale_msf(config_provider_oid) do
    P.request(@func_query_interface,
      type: @type_interface,
      oid: {config_provider_oid, @oid_config_provider}
    ) <> P.null_ctx() <> P.type_new(@xi_multi_service_factory, @qi_cache_locale_msf)
  end

  @doc false
  def qi_locale_na(config_access_oid) do
    P.request(@func_query_interface,
      type: @type_interface,
      oid: {config_access_oid, @oid_locale_config}
    ) <> P.null_ctx() <> P.type_new(@xi_name_access, @qi_cache_locale_na)
  end

  @doc false
  def qi_sfa(sfa_oid) do
    P.request(@func_query_interface, type: @type_interface, oid: {sfa_oid, @oid_sfa}) <>
      P.null_ctx() <> P.type_new(@xi_simple_file_access, @qi_cache_sfa)
  end

  @doc false
  def qi_sfa_output(os_oid) do
    P.request(@func_query_interface, type: @type_interface, oid: {os_oid, @oid_sfa_os}) <>
      P.null_ctx() <> P.type_new(@xi_output_stream, @qi_cache_sfa_output)
  end

  @doc false
  def qi_sfa_input(is_oid) do
    P.request(@func_query_interface, type: @type_interface, oid: {is_oid, @oid_sfa_is}) <>
      P.null_ctx() <> P.type_new(@xi_input_stream, @qi_cache_sfa_input)
  end

  ## ComponentContext

  @doc false
  def get_service_manager, do: @get_service_manager_frame

  @doc "XComponentContext.getValueByName — returns an Any(XInterface)."
  def get_value_by_name(ctx_oid, path) do
    P.request(@func_ctx_get_value_by_name,
      type: @type_component_ctx,
      oid: {ctx_oid, @oid_ctx}
    ) <> P.null_ctx() <> P.enc_str(path)
  end

  ## MultiComponentFactory

  @doc "XMultiComponentFactory.createInstanceWithContext (bootstrap — registers type)."
  def create_desktop(smgr_oid) do
    P.request(@func_mcf_create_with_context,
      type: @type_new_multi_comp_fac,
      oid: {smgr_oid, @oid_smgr}
    ) <> P.null_ctx() <> P.enc_str("com.sun.star.frame.Desktop") <> @ctx_ref
  end

  @doc "XMultiComponentFactory.createInstanceWithContext (cached type)."
  def create_instance_with_context(smgr_oid, service_name) do
    P.request(@func_mcf_create_with_context,
      type: @type_multi_comp_fac,
      oid: {smgr_oid, @oid_smgr}
    ) <> P.null_ctx() <> P.enc_str(service_name) <> @ctx_ref
  end

  @doc "XMultiComponentFactory.getAvailableServiceNames."
  def get_available_service_names(smgr_oid) do
    P.request(@func_mcf_get_avail_services,
      type: @type_multi_comp_fac,
      oid: {smgr_oid, @oid_smgr}
    ) <> P.null_ctx()
  end

  ## ComponentLoader

  @doc "XComponentLoader.loadComponentFromURL."
  def load_component_from_url(url, props) when is_list(props) do
    @load_url_prefix <>
      P.enc_str(url) <>
      P.enc_str("_blank") <>
      @frame_search_default <>
      <<length(props)>> <>
      IO.iodata_to_binary(props)
  end

  ## Storable2

  @doc "XStorable2.storeToURL."
  def store_to_url(url, props) when is_list(props) do
    prop_count = Enum.count(props, &(&1 != <<>>))

    @store_to_url_prefix <>
      P.enc_str(url) <>
      <<prop_count>> <>
      IO.iodata_to_binary(props)
  end

  ## Configuration

  @doc false
  def create_config_access, do: @create_config_access_frame

  @doc false
  def create_locale_config_access, do: @create_locale_config_access_frame

  @doc false
  def get_version, do: @get_version_frame

  @doc false
  def get_locale, do: @get_locale_frame

  ## NameAccess

  @doc "XNameAccess.getElementNames for FilterFactory."
  def get_filter_element_names do
    P.request(@func_na_get_element_names, type: @type_new_ff_name_access) <> P.null_ctx()
  end

  @doc "XNameAccess.getElementNames for TypeDetection."
  def get_type_element_names do
    P.request(@func_na_get_element_names, type: @type_new_td_name_access) <> P.null_ctx()
  end

  ## Closeable

  @doc false
  def close_document, do: @close_document_frame

  ## OutputStream / InputStream

  @doc false
  def write_bytes(bytes), do: @write_bytes_prefix <> P.enc_str(bytes)

  @doc false
  def close_output, do: @close_output_frame

  @doc false
  def read_all_bytes, do: @read_all_bytes_frame

  @doc false
  def close_input, do: @close_input_frame

  ## SimpleFileAccess

  @doc false
  def sfa_open_file_write(sfa_oid, url) do
    P.request(@func_sfa_open_file_write, type: @type_sfa, oid: {sfa_oid, @oid_sfa}) <>
      P.null_ctx() <> P.enc_str(url)
  end

  @doc false
  def sfa_open_file_read(sfa_oid, url) do
    P.request(@func_sfa_open_file_read, type: @type_sfa, oid: {sfa_oid, @oid_sfa}) <>
      P.null_ctx() <> P.enc_str(url)
  end

  @doc false
  def sfa_kill(sfa_oid, url) do
    P.request(@func_sfa_kill, type: @type_sfa, oid: {sfa_oid, @oid_sfa}) <>
      P.null_ctx() <> P.enc_str(url)
  end

  ## Property builders

  @doc false
  def hidden_property, do: P.property("Hidden", @tc_boolean, <<1>>)

  @doc false
  def filter_name_property(filter), do: P.property("FilterName", @tc_string, P.enc_str(filter))

  @doc "Build a FilterData property from a keyword list of export options."
  def filter_data_property([]), do: <<>>

  def filter_data_property(filter_data) do
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

  @doc "Build an InputStream property for streaming document load."
  def input_stream_property(stream_oid) do
    P.property(
      "InputStream",
      @tc_interface ||| @tc_new,
      <<@cache_export_input::16>> <>
        P.enc_str(@xi_input_stream) <>
        P.enc_str(stream_oid) <> <<@oid_export_input::16>>
    )
  end

  @doc "Build an OutputStream property for streaming document store."
  def output_stream_property(stream_oid) do
    P.property(
      "OutputStream",
      @tc_interface ||| @tc_new,
      <<@cache_export_output::16>> <>
        P.enc_str(@xi_output_stream) <>
        P.enc_str(stream_oid) <> <<@oid_export_output::16>>
    )
  end

  defp encode_any_value(true), do: {@tc_boolean, <<1>>}
  defp encode_any_value(false), do: {@tc_boolean, <<0>>}
  defp encode_any_value(n) when is_integer(n), do: {@tc_long, <<n::32-signed>>}
  defp encode_any_value(s) when is_binary(s), do: {@tc_string, P.enc_str(s)}
end

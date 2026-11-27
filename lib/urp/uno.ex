defmodule URP.UNO do
  @moduledoc false

  # The UNO methods the client calls.
  #
  # A method is identified by its interface and its position in it. Positions 0
  # to 2 are `queryInterface`, `acquire` and `release`; inherited methods come
  # next, then the interface's own in IDL order. The table below gives each
  # method that position, the types of its arguments and the type it returns.

  alias URP.Connection

  @object {:interface, "com.sun.star.uno.XInterface"}
  @context {:interface, "com.sun.star.uno.XComponentContext"}
  @property {:struct, "com.sun.star.beans.PropertyValue", [:string, :long, :any, :long]}
  @named_value {:struct, "com.sun.star.beans.NamedValue", [:string, :any]}
  @properties {:sequence, @property}

  @methods %{
    # XComponentContext
    get_value_by_name: {"com.sun.star.uno.XComponentContext", 3, [:string], :any},
    get_service_manager:
      {"com.sun.star.uno.XComponentContext", 4, [],
       {:interface, "com.sun.star.lang.XMultiComponentFactory"}},
    # XMultiComponentFactory
    create_instance_with_context:
      {"com.sun.star.lang.XMultiComponentFactory", 3, [:string, @context], @object},
    get_available_service_names:
      {"com.sun.star.lang.XMultiComponentFactory", 5, [], {:sequence, :string}},
    # XMultiServiceFactory
    create_instance_with_arguments:
      {"com.sun.star.lang.XMultiServiceFactory", 4, [:string, {:sequence, :any}], @object},
    # XComponentLoader, XStorable2, XCloseable
    load_component_from_url:
      {"com.sun.star.frame.XComponentLoader", 3, [:string, :string, :long, @properties], @object},
    store_to_url: {"com.sun.star.frame.XStorable2", 8, [:string, @properties], :void},
    close: {"com.sun.star.util.XCloseable", 5, [:boolean], :void},
    # XNameAccess, XNameReplace, XChangesBatch
    get_by_name: {"com.sun.star.container.XNameAccess", 5, [:string], :any},
    get_element_names: {"com.sun.star.container.XNameAccess", 6, [], {:sequence, :string}},
    replace_by_name: {"com.sun.star.container.XNameReplace", 8, [:string, :any], :void},
    commit_changes: {"com.sun.star.util.XChangesBatch", 3, [], :void},
    # XSimpleFileAccess
    kill: {"com.sun.star.ucb.XSimpleFileAccess", 5, [:string], :void},
    open_file_read:
      {"com.sun.star.ucb.XSimpleFileAccess", 15, [:string],
       {:interface, "com.sun.star.io.XInputStream"}},
    open_file_write:
      {"com.sun.star.ucb.XSimpleFileAccess", 16, [:string],
       {:interface, "com.sun.star.io.XOutputStream"}},
    # XInputStream, XOutputStream
    read_bytes: {"com.sun.star.io.XInputStream", 3, [:long], [:long, :bytes]},
    close_input: {"com.sun.star.io.XInputStream", 7, [], :void},
    write_bytes: {"com.sun.star.io.XOutputStream", 3, [:bytes], :void},
    close_output: {"com.sun.star.io.XOutputStream", 5, [], :void}
  }

  @typedoc "A value for an `any`: a boolean, an integer, a string or nested properties."
  @type value :: boolean() | integer() | String.t() | keyword(value())

  @doc "Call `method` on `object` with `args`, returning what it returns."
  @spec call(Connection.t(), String.t(), atom(), [term()]) :: term()
  def call(conn, object, method, args \\ []) do
    {interface, position, types, returns} = Map.fetch!(@methods, method)
    Connection.call(conn, object, interface, position, Enum.zip(types, args), returns)
  end

  @doc "Create an instance of `service` from the connection's service manager."
  @spec create_instance(Connection.t(), String.t()) :: String.t()
  def create_instance(conn, service) do
    call(conn, conn.service_manager, :create_instance_with_context, [service, conn.context])
  end

  @doc "A keyword list as a sequence of `PropertyValue`."
  @spec properties(keyword(value())) :: [list()]
  def properties(properties) do
    for {name, value} <- properties, do: [to_string(name), 0, any(value), 0]
  end

  @doc "A keyword list as a sequence of `NamedValue`, each in an `any`."
  @spec named_values(keyword(value())) :: [{tuple(), list()}]
  def named_values(values) do
    for {name, value} <- values, do: {@named_value, [to_string(name), any(value)]}
  end

  @doc "A value tagged with the UNO type it travels as."
  @spec any(value()) :: {URP.Protocol.type(), term()}
  def any(value) when is_boolean(value), do: {:boolean, value}
  def any(value) when is_integer(value), do: {:long, value}
  def any(value) when is_binary(value), do: {:string, value}
  def any(value) when is_list(value), do: {@properties, properties(value)}
end

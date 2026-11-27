defmodule URP.Bridge do
  @moduledoc false

  # The jobs a connection runs: converting a document, and reporting on
  # `soffice`.
  #
  # Each function takes a connection, returns its result and raises `URP.Error`
  # if it cannot go on. Anything it opens in `soffice` it closes in an `after`
  # block, so it is released however the job ends.

  alias URP.Connection
  alias URP.Sink
  alias URP.UNO

  @config_provider "/singletons/com.sun.star.configuration.theDefaultProvider"

  @doc """
  Convert `input` into `sink`: `:binary` to get the bytes back, `{:path, path}`
  or a function called with each chunk.

  `input` is a file path or `{:binary, bytes}`. Options are `:filter`,
  `:filter_data` and `:settings`, as `URP.convert/2` describes them.
  """
  @spec convert(Connection.t(), Path.t() | {:binary, binary()}, Sink.sink(), keyword()) ::
          binary() | :ok
  def convert(conn, input, sink, opts) do
    properties = [FilterName: Keyword.fetch!(opts, :filter)] ++ filter_data(opts[:filter_data])
    apply_settings(conn, Keyword.get(opts, :settings, []))

    load(conn, input, fn document ->
      Connection.checkpoint(conn)
      store(conn, document, properties, sink)
    end)
  end

  defp filter_data(empty) when empty in [nil, []], do: []
  defp filter_data(filter_data), do: [FilterData: filter_data]

  # soffice makes itself a stream over the document's bytes and loads from
  # that, so the document never touches its disk. The stream is held until the
  # document is gone, and then released so that soffice lets go of the bytes.
  defp load(conn, input, fun) do
    stream =
      UNO.call(conn, conn.service_manager, :create_instance_with_arguments_and_context, [
        "com.sun.star.io.SequenceInputStream",
        [{:bytes, read(input)}],
        conn.context
      ])

    try do
      Connection.checkpoint(conn)
      properties = UNO.properties(Hidden: true, InputStream: {:object, stream})

      document =
        UNO.call(conn, conn.desktop, :load_component_from_url, [
          "private:stream",
          "_blank",
          0,
          properties
        ]) ||
          raise URP.Error, "soffice could not load the document"

      try do
        fun.(document)
      after
        dispose(conn, document)
      end
    after
      Connection.release(conn, stream)
    end
  end

  # A document soffice no longer has cannot be disposed of, which is no
  # failure of the job. Either way it is no longer ours to hold.
  defp dispose(conn, document) do
    UNO.call(conn, document, :dispose)
  rescue
    URP.Error -> :ok
  after
    Connection.release(conn, document)
  end

  defp read({:binary, bytes}), do: bytes

  defp read(path) do
    case File.read(path) do
      {:ok, bytes} ->
        bytes

      {:error, reason} ->
        raise URP.Error, "could not read file #{path}: #{:file.format_error(reason)}"
    end
  end

  # soffice exports into a pipe it makes in its own memory, and the result is
  # read out of that a chunk at a time, so no message holds more of it than
  # that. Releasing the pipe lets go of whatever was not read.
  defp store(conn, document, properties, sink) do
    pipe = UNO.create_instance(conn, "com.sun.star.io.Pipe")

    try do
      properties = UNO.properties(properties ++ [OutputStream: {:object, pipe}])
      UNO.call(conn, document, :store_to_url, ["private:stream", properties])
      Connection.checkpoint(conn)
      collect(conn, pipe, sink)
    after
      Connection.release(conn, pipe)
    end
  end

  # A read that does not finish must not leave a half-written file behind.
  defp collect(conn, pipe, sink) do
    output = Sink.open(sink)

    try do
      # Not every filter closes the pipe when it is done, and a pipe left open
      # makes a read wait for all it was asked for. So only what is known to be
      # there is asked for.
      conn
      |> UNO.call(pipe, :available)
      |> Stream.unfold(fn
        0 ->
          nil

        left ->
          [read, chunk] = UNO.call(conn, pipe, :read_bytes, [min(left, conn.chunk_size)])
          {chunk, left - read}
      end)
      |> Enum.reduce(output, &Sink.write(&2, &1))
      |> Sink.finish()
    catch
      kind, reason ->
        Sink.release(output)
        with {:path, path} <- sink, do: File.rm(path)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  ## Settings

  @doc """
  Apply soffice configuration settings via
  [ConfigurationUpdateAccess](https://api.libreoffice.org/docs/idl/ref/servicecom_1_1sun_1_1star_1_1configuration_1_1ConfigurationUpdateAccess.html).

  Each setting is a `{path, property, value}` triplet where `path` is the
  registry node (e.g. `"org.openoffice.Office.Common/Cache/GraphicManager"`),
  `property` is the property name, and `value` is a boolean, integer, or string.
  Settings sharing a `path` are committed together.
  """
  @spec apply_settings(Connection.t(), [URP.setting()]) :: :ok
  def apply_settings(conn, settings) do
    for {path, group} <- Enum.group_by(settings, &elem(&1, 0)) do
      access = configuration(conn, "ConfigurationUpdateAccess", "/" <> path)

      for {_path, name, value} <- group do
        UNO.call(conn, access, :replace_by_name, [name, UNO.any(value)])
      end

      UNO.call(conn, access, :commit_changes)
    end

    :ok
  end

  ## Diagnostics

  @doc "The soffice version string, such as `\"26.2.0.3\"`."
  @spec version(Connection.t()) :: String.t()
  def version(conn) do
    access = configuration(conn, "ConfigurationAccess", "/org.openoffice.Setup/Product")
    UNO.call(conn, access, :get_by_name, ["ooSetupVersionAboutBox"])
  end

  @doc "The soffice locale, such as `\"en-US\"`."
  @spec locale(Connection.t()) :: String.t()
  def locale(conn) do
    access = configuration(conn, "ConfigurationAccess", "/org.openoffice.Setup/L10N")
    UNO.call(conn, access, :get_by_name, ["ooLocale"])
  end

  @doc "Every service name registered in the UNO service manager."
  @spec services(Connection.t()) :: [String.t()]
  def services(conn) do
    UNO.call(conn, conn.service_manager, :get_available_service_names)
  end

  @doc "Every filter name registered in soffice."
  @spec filters(Connection.t()) :: [String.t()]
  def filters(conn) do
    UNO.call(
      conn,
      UNO.create_instance(conn, "com.sun.star.document.FilterFactory"),
      :get_element_names
    )
  end

  @doc "Every document type name registered in soffice."
  @spec types(Connection.t()) :: [String.t()]
  def types(conn) do
    UNO.call(
      conn,
      UNO.create_instance(conn, "com.sun.star.document.TypeDetection"),
      :get_element_names
    )
  end

  defp configuration(conn, service, nodepath) do
    provider = UNO.call(conn, conn.context, :get_value_by_name, [@config_provider])

    UNO.call(conn, provider, :create_instance_with_arguments, [
      "com.sun.star.configuration." <> service,
      UNO.named_values(nodepath: nodepath)
    ])
  end
end

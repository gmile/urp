defmodule URP do
  @moduledoc """
  Pure Elixir client for document conversion via LibreOffice's UNO Remote Protocol.

  Talks directly to a `soffice` process over TCP.

  ## Setup

  With `:urp` among your dependencies, `convert/2` works against a `soffice`
  on `localhost:2002`. To point it elsewhere:

      # config/runtime.exs — every key is optional, defaults shown
      config :urp, :default,
        host: "localhost",
        port: 2002,
        pool_size: 1,           # connections, each converting one document at a time
        chunk_size: 1_048_576,  # bytes of a document moved per message
        drain_timeout: 300_000, # ms soffice may stay silent before a connection is dropped
        connect_timeout: 5_000, # ms
        backoff_initial: 500,   # ms, first delay before reconnecting
        backoff_max: 5_000      # ms, longest delay before reconnecting

  For several `soffice` instances, configure named pools the same way and pick
  one with the `:pool` option:

      config :urp, :pools, spreadsheets: [host: "soffice-2"]

  A pool connects when it is first used. If its `:host` resolves to several
  addresses, its connections are spread over them.

  ## Calls that outlive `:timeout`

  `soffice` cannot be told to stop: it finishes every call it was sent, and
  keeps a document it loaded until it is told to close it. So each connection
  is a process of its own that sees a job through. A caller waits `:timeout`
  and then gets `{:error, :timeout}`, while the connection waits for `soffice`,
  closes the document, deletes its temp files and only then takes another job.
  It reconnects only if `soffice` says nothing for the whole `:drain_timeout`.
  See `URP.Telemetry` for the event this emits.

  ## Errors

  A failure is `{:error, reason}`. A string is the reason this one job failed,
  from `soffice` or from reading the input or writing the output; the next
  call may well succeed. An atom means there was no answer to be had:
  `:timeout` if none came within `:timeout`, `:closed` or a POSIX error if the
  socket failed, `:unavailable` if the pool is not running and
  `:protocol_error` if the exchange went wrong, with the details logged.

      case URP.convert(path, filter: "writer_pdf_Export", output: pdf) do
        {:ok, ^pdf} -> :converted
        {:error, message} when is_binary(message) -> {:refused, message}
        {:error, reason} -> {:unavailable, reason}
      end

  The functions ending in `!` return the bare result and raise `URP.Error` for
  a string and `URP.SocketError` for an atom.

  ## Diagnostics

  `version/1`, `locale/1`, `services/1`, `filters/1` and `types/1` ask
  `soffice` about itself. Each takes `:pool` and `:timeout`.

  ## Testing

  See `URP.Test` for stubbing conversions without a `soffice`.
  """

  @typedoc "Why a call failed; see the Errors section of the module documentation."
  @type error :: String.t() | atom()

  @type setting :: {String.t(), String.t(), boolean() | integer() | String.t()}
  @type output :: Path.t() | :binary | (binary() -> any())

  @query_options NimbleOptions.new!(
                   pool: [type: :atom],
                   timeout: [type: :timeout, default: 120_000]
                 )

  @doc "The soffice version, such as `\"26.2.0.3\"`."
  @spec version(keyword()) :: {:ok, String.t()} | {:error, error()}
  def version(opts \\ []), do: query(:version, opts)

  @doc "The soffice locale, such as `\"en-US\"`, or `\"\"` if none is configured."
  @spec locale(keyword()) :: {:ok, String.t()} | {:error, error()}
  def locale(opts \\ []), do: query(:locale, opts)

  @doc "Every service registered in soffice, such as `\"com.sun.star.frame.Desktop\"`."
  @spec services(keyword()) :: {:ok, [String.t()]} | {:error, error()}
  def services(opts \\ []), do: query(:services, opts)

  @doc "Every filter soffice knows, such as `\"writer_pdf_Export\"`; any can be passed as `:filter`."
  @spec filters(keyword()) :: {:ok, [String.t()]} | {:error, error()}
  def filters(opts \\ []), do: query(:filters, opts)

  @doc "Every document type soffice detects, such as `\"writer8\"`."
  @spec types(keyword()) :: {:ok, [String.t()]} | {:error, error()}
  def types(opts \\ []), do: query(:types, opts)

  @doc "Like `version/1` but raises on error."
  @spec version!(keyword()) :: String.t()
  def version!(opts \\ []), do: opts |> version() |> unwrap!()

  @doc "Like `locale/1` but raises on error."
  @spec locale!(keyword()) :: String.t()
  def locale!(opts \\ []), do: opts |> locale() |> unwrap!()

  @doc "Like `services/1` but raises on error."
  @spec services!(keyword()) :: [String.t()]
  def services!(opts \\ []), do: opts |> services() |> unwrap!()

  @doc "Like `filters/1` but raises on error."
  @spec filters!(keyword()) :: [String.t()]
  def filters!(opts \\ []), do: opts |> filters() |> unwrap!()

  @doc "Like `types/1` but raises on error."
  @spec types!(keyword()) :: [String.t()]
  def types!(opts \\ []), do: opts |> types() |> unwrap!()

  defp query(operation, opts) do
    {pool, opts} = opts |> NimbleOptions.validate!(@query_options) |> Keyword.pop(:pool)
    URP.Pool.run(ensure_pool!(pool), operation, opts, &apply(URP.Bridge, operation, [&1]))
  end

  @scalar {:or, [:boolean, :integer, :string]}

  @convert_options NimbleOptions.new!(
                     filter: [
                       type: :string,
                       required: true,
                       doc:
                         "Export filter name, such as `\"writer_pdf_Export\"`, `\"calc_pdf_Export\"`, " <>
                           "`\"impress_pdf_Export\"` or `\"Markdown\"`."
                     ],
                     filter_data: [
                       type: :keyword_list,
                       keys: [*: [type: @scalar]],
                       default: [],
                       doc: """
                       Filter-specific export options, with boolean, integer or string values. \
                       For PDF filters, see [PDF export options](https://wiki.documentfoundation.org/API/Tutorials/PDF_export) \
                       (e.g. `[UseLosslessCompression: true, ExportFormFields: false]`).
                       """
                     ],
                     settings: [
                       type: {:list, {:tuple, [:string, :string, @scalar]}},
                       type_doc: "list of `t:setting/0`",
                       default: [],
                       doc: """
                       `{path, property, value}` triplets to set on soffice before the conversion \
                       via `ConfigurationUpdateAccess`, for tuning cache limits, graphic memory and \
                       the like. They change the soffice process-wide profile and outlast the \
                       conversion; do not vary them concurrently on a shared soffice. See the \
                       [officecfg schema](https://github.com/LibreOffice/core/tree/master/officecfg/registry/schema/org/openoffice/Office) \
                       for what can be set.
                       """
                     ],
                     output: [
                       type: {:or, [{:in, [:binary]}, :string, {:fun, 1}]},
                       type_doc: "`t:output/0`",
                       required: true,
                       doc: """
                       Where the converted document goes.

                         * a path — written there; returns `{:ok, path}`
                         * `:binary` — returns `{:ok, bytes}`
                         * a function — called with each chunk, in the connection's process \
                           rather than the caller's; returns `:ok`
                       """
                     ],
                     pool: [
                       type: :atom,
                       doc: "Named pool to use, instead of the default one."
                     ],
                     timeout: [
                       type: :timeout,
                       default: 120_000,
                       doc:
                         "How long to wait for the result, in ms: for a connection to come free " <>
                           "and then for the conversion."
                     ]
                   )

  @doc """
  Convert a document via LibreOffice.

  `input` is a file path, read from the local disk a chunk at a time, or
  `{:binary, bytes}` for a document already in memory. Either way it is sent
  over the socket and `soffice` works from a temp file of its own, so nothing
  has to be shared with it on disk.

  ## Options

  #{NimbleOptions.docs(@convert_options)}

  ## Examples

      {:ok, "/tmp/out.pdf"} =
        URP.convert("/tmp/report.docx", filter: "writer_pdf_Export", output: "/tmp/out.pdf")

      {:ok, pdf_bytes} =
        URP.convert({:binary, docx_bytes}, filter: "writer_pdf_Export", output: :binary)

  With soffice settings (e.g. raise graphic memory cache for image-heavy docs):

      {:ok, pdf} = URP.convert("charts.pptx",
        filter: "impress_pdf_Export",
        output: :binary,
        settings: [
          {"org.openoffice.Office.Common/Cache/GraphicManager", "GraphicMemoryLimit", 500_000_000}
        ]
      )

  Options are checked before anything is sent:

      iex> URP.convert({:binary, "bytes"}, output: :binary)
      ** (NimbleOptions.ValidationError) required :filter option not found, received options: [:output]
  """
  @spec convert(Path.t() | {:binary, binary()}, keyword()) ::
          {:ok, Path.t()} | {:ok, binary()} | :ok | {:error, error()}
  def convert(input, opts)
      when is_binary(input) or (is_tuple(input) and elem(input, 0) == :binary) do
    validated = NimbleOptions.validate!(opts, @convert_options)

    with :error <- URP.Test.__fetch_stub__() do
      {output, validated} = Keyword.pop!(validated, :output)
      {pool, validated} = Keyword.pop(validated, :pool)
      {pool_opts, job_opts} = Keyword.split(validated, [:timeout])
      sink = if is_binary(output), do: {:path, output}, else: output

      case URP.Pool.run(
             ensure_pool!(pool),
             :convert,
             pool_opts,
             &URP.Bridge.convert(&1, input, sink, job_opts)
           ) do
        {:ok, :ok} when is_binary(output) -> {:ok, output}
        {:ok, :ok} -> :ok
        result -> result
      end
    else
      {:ok, stub} -> stub.(input, opts)
    end
  end

  @doc "Like `convert/2` but raises on error."
  @spec convert!(Path.t() | {:binary, binary()}, keyword()) :: Path.t() | binary() | :ok
  def convert!(input, opts), do: input |> convert(opts) |> unwrap!()

  defp unwrap!({:ok, value}), do: value
  defp unwrap!(:ok), do: :ok
  defp unwrap!({:error, message}) when is_binary(message), do: raise(URP.Error, message)
  defp unwrap!({:error, reason}), do: raise(URP.SocketError, reason: reason)

  # Pools start on first use: the one configured under `config :urp, :default`
  # when no `:pool` is given, otherwise the named one under `config :urp, :pools`.
  @doc false
  def ensure_pool!(nil), do: start_pool(URP.Pool.Default, Application.get_env(:urp, :default, []))

  def ensure_pool!(name) do
    case Keyword.fetch(Application.get_env(:urp, :pools, []), name) do
      {:ok, config} ->
        start_pool(:"URP.Pool.#{name}", config)

      :error ->
        raise ArgumentError,
              "pool #{inspect(name)} is not configured. " <>
                "Add it to config :urp, :pools, #{name}: [host: \"...\", port: 2002]"
    end
  end

  defp start_pool(process, config) do
    if is_nil(GenServer.whereis(process)) do
      spec = {URP.Pool, Keyword.put(config, :name, process)}

      # Losing a race to start the pool is as good as winning it.
      with {:error, reason} <- DynamicSupervisor.start_child(URP.PoolSupervisor, spec),
           nil <- GenServer.whereis(process) do
        raise "could not start pool #{inspect(process)}: #{inspect(reason)}"
      end
    end

    process
  end
end

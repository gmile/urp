defmodule URP do
  @moduledoc """
  Pure Elixir client for document conversion via LibreOffice's UNO Remote Protocol.

  Talks directly to a `soffice` process over TCP.
  No Python, no unoserver, no Gotenberg.

  ## Setup

  Add `:urp` to your dependencies — that's it. A default connection pool
  starts automatically, connecting to `localhost:2002`.

      # config/runtime.exs (optional — defaults shown)
      config :urp, :default,
        host: "soffice",
        port: 2002,
        pool_size: 1

  See `convert/2` for usage examples and options.

  ## Diagnostics

  Query soffice state without converting anything:

      {:ok, "25.8.1.1"} = URP.version()
      {:ok, services} = URP.services()
      {:ok, filters} = URP.filters()
      {:ok, types} = URP.types()
      {:ok, locale} = URP.locale()

  ## Named pools

  For multiple soffice instances, configure named pools:

      config :urp, :pools,
        spreadsheets: [host: "soffice-2", port: 2002, pool_size: 3]

      {:ok, pdf} = URP.convert({:binary, bytes}, filter: "calc_pdf_Export", pool: :spreadsheets)

  Named pools are started on first use.

  ## Testing

      URP.Test.stub(fn _input, _opts -> {:ok, "/tmp/fake.pdf"} end)
      {:ok, _} = URP.convert({:binary, docx_bytes}, filter: "writer_pdf_Export")

  See `URP.Test` for details.
  """

  @type output :: Path.t() | :binary | (binary() -> any())
  @type opt ::
          {:output, output()}
          | {:pool, atom()}
          | {:filter, String.t()}
          | {:filter_data, keyword()}
          | {:timeout, non_neg_integer()}

  @doc """
  Query the soffice version string over URP.

  Returns the raw version string (e.g. `"25.8.1.1"`). Callers can use
  `Version.parse/1` if needed.

  ## Examples

      {:ok, version} = URP.version()
      # => "25.8.1.1"

  ## Options

    * `:pool`    — named pool to use (default: the auto-started pool)
    * `:timeout` — checkout timeout in ms (default `120_000`)
  """
  @spec version(keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def version(opts \\ []) do
    {pool, opts} = resolve_pool(opts)
    URP.Pool.version(pool, opts)
  end

  @doc """
  List all service names registered in the UNO service manager.

  Returns a list of service name strings like `"com.sun.star.frame.Desktop"`.

  ## Examples

      {:ok, services} = URP.services()
      "com.sun.star.frame.Desktop" in services
      # => true

  ## Options

    * `:pool`    — named pool to use (default: the auto-started pool)
    * `:timeout` — checkout timeout in ms (default `120_000`)
  """
  @spec services(keyword()) :: {:ok, [String.t()]} | {:error, String.t()}
  def services(opts \\ []) do
    {pool, opts} = resolve_pool(opts)
    URP.Pool.services(pool, opts)
  end

  @doc """
  List all export filter names registered in soffice.

  Returns a list of filter name strings like `"writer_pdf_Export"`.
  Useful for discovering which filters are available on the connected soffice.

  ## Examples

      {:ok, filters} = URP.filters()
      "writer_pdf_Export" in filters
      # => true

  ## Options

    * `:pool`    — named pool to use (default: the auto-started pool)
    * `:timeout` — checkout timeout in ms (default `120_000`)
  """
  @spec filters(keyword()) :: {:ok, [String.t()]} | {:error, String.t()}
  def filters(opts \\ []) do
    {pool, opts} = resolve_pool(opts)
    URP.Pool.filters(pool, opts)
  end

  @doc """
  List all document type names registered in soffice.

  Returns a list of type name strings like `"writer8"`.
  These are the internal names soffice uses for file format detection.

  ## Examples

      {:ok, types} = URP.types()
      "writer8" in types
      # => true

  ## Options

    * `:pool`    — named pool to use (default: the auto-started pool)
    * `:timeout` — checkout timeout in ms (default `120_000`)
  """
  @spec types(keyword()) :: {:ok, [String.t()]} | {:error, String.t()}
  def types(opts \\ []) do
    {pool, opts} = resolve_pool(opts)
    URP.Pool.types(pool, opts)
  end

  @doc """
  Query the soffice locale string.

  Returns the locale string (e.g. `"en-US"`) or `""` if not configured.

  ## Examples

      {:ok, locale} = URP.locale()
      # => "en-US"

  ## Options

    * `:pool`    — named pool to use (default: the auto-started pool)
    * `:timeout` — checkout timeout in ms (default `120_000`)
  """
  @spec locale(keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def locale(opts \\ []) do
    {pool, opts} = resolve_pool(opts)
    URP.Pool.locale(pool, opts)
  end

  @doc """
  Convert a document via LibreOffice.

  ## Input types

    * `path` (binary) — local file path, loaded via file-backed streaming
    * `{:binary, bytes}` — raw document bytes
    * enumerable — any `Enumerable` (e.g. `File.stream!/2`), streamed lazily

  ## Options

    * `:filter`  — export filter name (**required**). See moduledoc for common filters.
    * `:filter_data` — keyword list of filter-specific export options.
      Values can be booleans, integers, or strings.
      For PDF filters, see [PDF export options](https://wiki.documentfoundation.org/API/Tutorials/PDF_export)
      (e.g. `[UseLosslessCompression: true, ExportFormFields: false]`).
    * `:output`  — where to write converted output:
      * path string — write to file, returns `{:ok, path}`
      * `:binary` — return bytes, returns `{:ok, bytes}`
      * `fun/1` — call with each chunk, returns `:ok`
      * not set — write to temp file, returns `{:ok, tmp_path}`
    * `:pool`    — named pool to use (default: the auto-started pool)
    * `:timeout` — checkout timeout in ms (default `120_000`)

  ## Examples

  File path input with various output modes:

      {:ok, pdf_path} = URP.convert("/tmp/report.docx", filter: "writer_pdf_Export")
      {:ok, "/tmp/out.pdf"} = URP.convert("/tmp/report.docx", filter: "writer_pdf_Export", output: "/tmp/out.pdf")
      {:ok, pdf_bytes} = URP.convert("/tmp/report.docx", filter: "writer_pdf_Export", output: :binary)

  Raw bytes:

      {:ok, pdf_bytes} = URP.convert({:binary, docx_bytes}, filter: "writer_pdf_Export", output: :binary)

  Enumerable (e.g. streaming a large file):

      {:ok, pdf_path} = URP.convert(File.stream!("huge.docx", 65_536), filter: "writer_pdf_Export")

  The `:filter` option is required:

      iex> URP.convert({:binary, "bytes"}, output: :binary)
      ** (ArgumentError) URP.convert/2 requires the :filter option. Common filters: "writer_pdf_Export", "calc_pdf_Export", "impress_pdf_Export", "Markdown"

  With a test stub (see `URP.Test`):

      iex> URP.Test.stub(fn _input, _opts -> {:ok, "/tmp/fake.pdf"} end)
      :ok
      iex> URP.convert("/tmp/test.docx", filter: "writer_pdf_Export")
      {:ok, "/tmp/fake.pdf"}
  """
  @spec convert(binary() | {:binary, binary()} | Enumerable.t(), [opt()]) ::
          {:ok, Path.t()} | {:ok, binary()} | :ok | {:error, String.t()}
  def convert(input, opts \\ [])

  def convert(input, opts) when is_binary(input) and is_list(opts) do
    do_convert(input, opts)
  end

  def convert({:binary, bytes} = input, opts) when is_binary(bytes) and is_list(opts) do
    do_convert(input, opts)
  end

  def convert(input, opts) when is_list(opts) do
    if Enumerable.impl_for(input) do
      do_convert(input, opts)
    else
      raise ArgumentError,
            "URP.convert/2 expects a file path (binary), {:binary, bytes}, or an Enumerable. " <>
              "Got: #{inspect(input)}"
    end
  end

  defp do_convert(input, opts) do
    case URP.Test.__fetch_stub__() do
      {:ok, fun} ->
        fun.(input, opts)

      :error ->
        if not Keyword.has_key?(opts, :filter) do
          raise ArgumentError,
                "URP.convert/2 requires the :filter option. " <>
                  "Common filters: \"writer_pdf_Export\", \"calc_pdf_Export\", \"impress_pdf_Export\", \"Markdown\""
        end

        {pool, opts} = resolve_pool(opts)
        {output, opts} = Keyword.pop(opts, :output)

        pool_opts =
          case output do
            nil ->
              tmp = generate_tmp_path(input, opts[:filter])
              Keyword.put(opts, :sink, {:path, tmp})

            :binary ->
              opts

            path when is_binary(path) ->
              Keyword.put(opts, :sink, {:path, path})

            fun when is_function(fun, 1) ->
              Keyword.put(opts, :sink, fun)
          end

        case URP.Pool.convert(pool, input, pool_opts) do
          :ok when is_nil(output) -> {:ok, elem(pool_opts[:sink], 1)}
          :ok when is_binary(output) -> {:ok, output}
          :ok when is_function(output, 1) -> :ok
          {:ok, _bytes} = ok when output == :binary -> ok
          {:error, _msg} = err -> err
        end
    end
  end

  @filter_extensions %{
    "writer_pdf_Export" => ".pdf",
    "calc_pdf_Export" => ".pdf",
    "impress_pdf_Export" => ".pdf",
    "draw_pdf_Export" => ".pdf",
    "Markdown" => ".md",
    "HTML (StarWriter)" => ".html",
    "HTML (StarCalc)" => ".html",
    "Rich Text Format" => ".rtf",
    "Text" => ".txt",
    "Text (encoded)" => ".txt",
    "Office Open XML Text" => ".docx",
    "writer8" => ".odt"
  }

  defp generate_tmp_path(input, filter) do
    basename =
      case input do
        path when is_binary(path) -> Path.basename(path, Path.extname(path))
        _ -> "urp"
      end

    ext = Map.get(@filter_extensions, filter, ".bin")
    id = :erlang.unique_integer([:positive])
    Path.join(System.tmp_dir!(), "#{basename}_#{id}#{ext}")
  end

  defp resolve_pool(opts) do
    {pool_name, opts} = Keyword.pop(opts, :pool)
    pool = if pool_name, do: ensure_pool!(pool_name), else: URP.Pool.Default
    {pool, opts}
  end

  @doc false
  def ensure_pool!(name) do
    pid_name = pool_process_name(name)

    case GenServer.whereis(pid_name) do
      pid when is_pid(pid) ->
        pid_name

      nil ->
        pools = Application.get_env(:urp, :pools, [])

        case Keyword.fetch(pools, name) do
          {:ok, config} ->
            opts = [
              name: pid_name,
              host: Keyword.get(config, :host, "localhost"),
              port: Keyword.get(config, :port, 2002),
              pool_size: Keyword.get(config, :pool_size, 1)
            ]

            case DynamicSupervisor.start_child(URP.PoolSupervisor, {URP.Pool, opts}) do
              {:ok, _pid} -> pid_name
              {:error, {:already_started, _pid}} -> pid_name
            end

          :error ->
            raise ArgumentError,
                  "pool #{inspect(name)} is not configured. " <>
                    "Add it to config :urp, :pools, #{name}: [host: \"...\", port: 2002]"
        end
    end
  end

  defp pool_process_name(name), do: :"URP.Pool.#{name}"
end

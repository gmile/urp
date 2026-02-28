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

  ## Usage

      {:ok, pdf_bytes} = URP.convert_stream(docx_bytes)
      {:ok, pdf_bytes} = URP.convert_file_stream("/path/to/input.docx")
      :ok = URP.convert_stream(docx_bytes, sink: {:path, "/tmp/out.pdf"})

  ## Named pools

  For multiple soffice instances, configure named pools:

      config :urp, :pools,
        spreadsheets: [host: "soffice-2", port: 2002, pool_size: 3]

      {:ok, pdf} = URP.convert_stream(bytes, pool: :spreadsheets)

  Named pools are started on first use.

  ## Testing

      URP.Test.stub(fn _input, _opts -> {:ok, "fake pdf"} end)
      {:ok, "fake pdf"} = URP.convert_stream(docx_bytes)

  See `URP.Test` for details.
  """

  @type sink :: {:path, Path.t()} | (binary() -> any())
  @type opt ::
          {:pool, atom()}
          | {:filter, String.t()}
          | {:sink, sink()}
          | {:timeout, non_neg_integer()}

  @doc """
  Convert document bytes to PDF via streaming.

  ## Options

    * `:pool`    — named pool to use (default: `URP.Pool.Default`)
    * `:filter`  — export filter name (default `"writer_pdf_Export"`)
    * `:sink`    — output destination: `{:path, path}` or `fun/1` (default: in-memory)
    * `:timeout` — checkout timeout in ms (default `120_000`)
  """
  @spec convert_stream(binary(), [opt()]) :: {:ok, binary()} | :ok | {:error, String.t()}
  def convert_stream(input_bytes, opts \\ []) when is_binary(input_bytes) do
    case URP.Test.__fetch_stub__() do
      {:ok, fun} ->
        fun.(input_bytes, opts)

      :error ->
        {pool, opts} = resolve_pool(opts)
        URP.Pool.convert_stream(pool, input_bytes, opts)
    end
  end

  @doc """
  Convert a local file to PDF via file-backed streaming.

  Accepts the same options as `convert_stream/2`.
  """
  @spec convert_file_stream(Path.t(), [opt()]) :: {:ok, binary()} | :ok | {:error, String.t()}
  def convert_file_stream(input_path, opts \\ []) when is_binary(input_path) do
    case URP.Test.__fetch_stub__() do
      {:ok, fun} ->
        fun.(input_path, opts)

      :error ->
        {pool, opts} = resolve_pool(opts)
        URP.Pool.convert_file_stream(pool, input_path, opts)
    end
  end

  @doc """
  Convert a file to PDF via file:// URLs (requires shared filesystem).

  ## Options

    * `:pool`    — named pool to use (default: `URP.Pool.Default`)
    * `:filter`  — export filter name (default `"writer_pdf_Export"`)
    * `:timeout` — checkout timeout in ms (default `120_000`)
  """
  @spec convert(Path.t(), Path.t() | nil, [opt()]) ::
          {:ok, Path.t()} | {:error, String.t()}
  def convert(input_path, output_path \\ nil, opts \\ []) do
    case URP.Test.__fetch_stub__() do
      {:ok, fun} ->
        fun.(input_path, opts)

      :error ->
        {pool, opts} = resolve_pool(opts)
        URP.Pool.convert(pool, input_path, output_path, opts)
    end
  end

  defp resolve_pool(opts) do
    {pool_name, opts} = Keyword.pop(opts, :pool)

    pool =
      if pool_name do
        ensure_pool!(pool_name)
      else
        URP.Pool.Default
      end

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

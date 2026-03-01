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

      # File path (most common)
      {:ok, pdf_path} = URP.convert("/tmp/in.docx")
      {:ok, "/tmp/out.pdf"} = URP.convert("/tmp/in.docx", output: "/tmp/out.pdf")
      {:ok, pdf_bytes} = URP.convert("/tmp/in.docx", output: :binary)
      :ok = URP.convert("/tmp/in.docx", output: fn chunk -> send(self(), chunk) end)

      # Raw bytes
      {:ok, pdf_path} = URP.convert({:binary, docx_bytes})
      {:ok, pdf_bytes} = URP.convert({:binary, docx_bytes}, output: :binary)

      # Enumerable (e.g. File.stream!, S3 download stream)
      {:ok, pdf_path} = URP.convert(File.stream!("huge.docx", 65_536))

  ## Options

    * `:output`  — where to write: path string, `:binary`, or `fun/1` (default: temp file)
    * `:pool`    — named pool to use (default: `URP.Pool.Default`)
    * `:filter`  — export filter name (default `"writer_pdf_Export"`)
    * `:timeout` — checkout timeout in ms (default `120_000`)

  ## Named pools

  For multiple soffice instances, configure named pools:

      config :urp, :pools,
        spreadsheets: [host: "soffice-2", port: 2002, pool_size: 3]

      {:ok, pdf} = URP.convert({:binary, bytes}, pool: :spreadsheets)

  Named pools are started on first use.

  ## Testing

      URP.Test.stub(fn _input, _opts -> {:ok, "fake pdf"} end)
      {:ok, "fake pdf"} = URP.convert({:binary, docx_bytes}, output: :binary)

  See `URP.Test` for details.
  """

  @type output :: Path.t() | :binary | (binary() -> any())
  @type opt ::
          {:output, output()}
          | {:pool, atom()}
          | {:filter, String.t()}
          | {:timeout, non_neg_integer()}

  @doc """
  Convert a document via LibreOffice.

  The output format is determined by the `:filter` option (default: `"writer_pdf_Export"`).

  ## Input types

    * `path` (binary) — local file path, loaded via file-backed streaming
    * `{:binary, bytes}` — raw document bytes
    * enumerable — any `Enumerable` (e.g. `File.stream!/2`), streamed lazily

  ## Options

    * `:output`  — where to write converted output:
      * path string — write to file, returns `{:ok, path}`
      * `:binary` — return bytes, returns `{:ok, bytes}`
      * `fun/1` — call with each chunk, returns `:ok`
      * not set — write to temp file, returns `{:ok, tmp_path}`
    * `:pool`    — named pool to use (default: `URP.Pool.Default`)
    * `:filter`  — export filter name (default `"writer_pdf_Export"`)
    * `:timeout` — checkout timeout in ms (default `120_000`)
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
        {pool, opts} = resolve_pool(opts)
        {output, opts} = Keyword.pop(opts, :output)

        pool_opts =
          case output do
            nil ->
              tmp = generate_tmp_path(input)
              Keyword.put(opts, :sink, {:path, tmp})

            :binary ->
              opts

            path when is_binary(path) ->
              Keyword.put(opts, :sink, {:path, path})

            fun when is_function(fun, 1) ->
              Keyword.put(opts, :sink, fun)
          end

        result = URP.Pool.convert(pool, input, pool_opts)

        case {output, result} do
          {nil, :ok} ->
            {:ok, pool_opts[:sink] |> elem(1)}

          {path, :ok} when is_binary(path) ->
            {:ok, path}

          {fun, :ok} when is_function(fun, 1) ->
            :ok

          _ ->
            result
        end
    end
  end

  defp generate_tmp_path(input) do
    basename =
      case input do
        path when is_binary(path) -> Path.basename(path, Path.extname(path))
        _ -> "urp"
      end

    id = :erlang.unique_integer([:positive])
    Path.join(System.tmp_dir!(), "#{basename}_#{id}.pdf")
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

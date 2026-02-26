defmodule URP.Pool do
  @moduledoc """
  Connection pool for concurrent document conversion.

  Manages a pool of `URP.Bridge` connections via `NimblePool`.

  The default pool size is **1** — appropriate when talking to a single soffice
  instance (soffice is single-threaded, so concurrent connections don't improve
  throughput). Increase `pool_size` when you have multiple soffice replicas
  behind a load balancer or round-robin DNS.

  ## Setup

      # In your application supervision tree
      children = [
        {URP.Pool, otp_app: :my_app}
      ]

  ## Usage

      {:ok, pdf} = URP.Pool.convert_stream(bytes)
      {:ok, pdf} = URP.Pool.convert_stream(MyPool, bytes, filter: "calc_pdf_Export")
      :ok = URP.Pool.convert_stream(bytes, sink: {:path, "/tmp/out.pdf"})

  ## Connection lifecycle

  URL-based conversions (`convert/4`) reuse connections across calls.
  Streaming conversions (`convert_stream/3`, `convert_file_stream/3`) consume
  the connection — soffice closes the TCP socket after streaming store — so the
  pool transparently replaces it with a fresh one.
  """

  @behaviour NimblePool

  alias URP.Bridge

  @default_timeout 120_000

  @doc """
  Start a connection pool.

  ## Options

    * `:name`      — process name (default `URP.Pool`)
    * `:otp_app`   — application to read config from (reads
      `Application.get_env(otp_app, URP.Pool, [])` at runtime)
    * `:host`      — soffice hostname (default `"localhost"`)
    * `:port`      — soffice URP listener port (default `2002`)
    * `:pool_size` — number of connections (default `1`). Increase when
      running multiple soffice replicas behind a load balancer.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    {otp_app, opts} = Keyword.pop(opts, :otp_app)

    resolved =
      if otp_app do
        runtime = Application.get_env(otp_app, __MODULE__, [])
        Keyword.merge(opts, runtime)
      else
        opts
      end

    {pool_size, resolved} = Keyword.pop(resolved, :pool_size, 1)

    NimblePool.start_link(
      worker: {__MODULE__, Map.new(resolved)},
      pool_size: pool_size,
      name: name
    )
  end

  @doc false
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  @doc """
  Convert document bytes to PDF via streaming.

  ## Options

    * `:filter`  — export filter name (default `"writer_pdf_Export"`)
    * `:sink`    — output destination: `{:path, path}` or `fun/1` (default: in-memory)
    * `:timeout` — checkout timeout in ms (default `#{@default_timeout}`)
  """
  @spec convert_stream(NimblePool.pool(), binary(), keyword()) ::
          {:ok, binary()} | :ok | {:error, String.t()}
  def convert_stream(pool \\ __MODULE__, input_bytes, opts \\ [])
      when is_binary(input_bytes) do
    {timeout, opts} = Keyword.pop(opts, :timeout, @default_timeout)
    store_opts = Keyword.take(opts, [:filter, :sink])

    NimblePool.checkout!(
      pool,
      :checkout,
      fn _from, conn ->
        try do
          doc = Bridge.load_document_stream!(conn, input_bytes)
          result = Bridge.store_to_stream!(conn, doc, store_opts)
          {wrap_result(result), :closed}
        rescue
          e -> {{:error, Exception.message(e)}, :closed}
        end
      end,
      timeout
    )
  end

  @doc """
  Convert a local file to PDF via file-backed streaming.

  ## Options

    * `:filter`  — export filter name (default `"writer_pdf_Export"`)
    * `:sink`    — output destination: `{:path, path}` or `fun/1` (default: in-memory)
    * `:timeout` — checkout timeout in ms (default `#{@default_timeout}`)
  """
  @spec convert_file_stream(NimblePool.pool(), Path.t(), keyword()) ::
          {:ok, binary()} | :ok | {:error, String.t()}
  def convert_file_stream(pool \\ __MODULE__, input_path, opts \\ [])
      when is_binary(input_path) do
    {timeout, opts} = Keyword.pop(opts, :timeout, @default_timeout)
    store_opts = Keyword.take(opts, [:filter, :sink])

    NimblePool.checkout!(
      pool,
      :checkout,
      fn _from, conn ->
        try do
          doc = Bridge.load_document_file_stream!(conn, input_path)
          result = Bridge.store_to_stream!(conn, doc, store_opts)
          {wrap_result(result), :closed}
        rescue
          e -> {{:error, Exception.message(e)}, :closed}
        end
      end,
      timeout
    )
  end

  @doc """
  Convert a file to PDF via file:// URLs (requires shared filesystem).

  The connection is reused after this call.

  ## Options

    * `:filter`  — export filter name (default `"writer_pdf_Export"`)
    * `:timeout` — checkout timeout in ms (default `#{@default_timeout}`)
  """
  @spec convert(NimblePool.pool(), Path.t(), Path.t() | nil, keyword()) ::
          {:ok, Path.t()} | {:error, String.t()}
  def convert(pool \\ __MODULE__, input_path, output_path \\ nil, opts \\ []) do
    {timeout, opts} = Keyword.pop(opts, :timeout, @default_timeout)
    output_path = output_path || Path.rootname(input_path) <> ".pdf"
    filter = Keyword.get(opts, :filter, "writer_pdf_Export")
    in_url = "file://" <> Path.expand(input_path)
    out_url = "file://" <> Path.expand(output_path)

    NimblePool.checkout!(
      pool,
      :checkout,
      fn _from, conn ->
        try do
          doc = Bridge.load_document!(conn, in_url)
          Bridge.store_to_url!(conn, doc, out_url, filter)
          Bridge.close_document!(conn, doc)
          {{:ok, output_path}, {:ok, conn}}
        rescue
          e -> {{:error, Exception.message(e)}, :closed}
        end
      end,
      timeout
    )
  end

  ## NimblePool callbacks

  @impl NimblePool
  def init_pool(config) do
    {:ok, config}
  end

  @impl NimblePool
  def init_worker(config) do
    host = Map.get(config, :host, "localhost")
    port = Map.get(config, :port, 2002)
    conn = Bridge.open!(host, port)
    {:ok, conn, config}
  end

  @impl NimblePool
  def handle_checkout(:checkout, _from, conn, pool_state) do
    {:ok, conn, conn, pool_state}
  end

  @impl NimblePool
  def handle_checkin(:closed, _from, _worker_state, pool_state) do
    {:remove, :closed, pool_state}
  end

  def handle_checkin({:ok, conn}, _from, _worker_state, pool_state) do
    {:ok, conn, pool_state}
  end

  @impl NimblePool
  def terminate_worker(_reason, conn, pool_state) do
    if is_struct(conn, Bridge) do
      Bridge.close!(conn)
    end

    {:ok, pool_state}
  end

  defp wrap_result(:ok), do: :ok
  defp wrap_result(bytes) when is_binary(bytes), do: {:ok, bytes}
end

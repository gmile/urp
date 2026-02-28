defmodule URP.Pool do
  @moduledoc """
  Connection pool for concurrent document conversion.

  Manages a pool of `URP.Bridge` connections via `NimblePool`.
  Pools are started and managed by `URP.Application` — you don't need to
  add `URP.Pool` to your own supervision tree.

  The default pool size is **1** — appropriate when talking to a single soffice
  instance (soffice is single-threaded, so concurrent connections don't improve
  throughput). Increase `pool_size` when you have multiple soffice replicas
  behind a load balancer or round-robin DNS.

  ## Usage

      {:ok, pdf} = URP.Pool.convert_stream(URP.Pool.Default, bytes)
      {:ok, pdf} = URP.Pool.convert_stream(URP.Pool.Default, bytes, filter: "calc_pdf_Export")

  ## Connection lifecycle

  URL-based conversions (`convert/4`) reuse connections across calls.
  Streaming conversions (`convert_stream/3`, `convert_file_stream/3`) consume
  the connection — soffice closes the TCP socket after streaming store — so the
  pool transparently replaces it with a fresh one.
  """

  @behaviour NimblePool

  alias URP.Bridge

  @default_timeout 120_000

  # soffice's URP bridge transitions to STATE_TERMINATED when a connection
  # closes, revoking stubs from the UNO environment. If we reconnect before
  # that cleanup finishes, the new bridge may throw DisposedException
  # ("Binary URP bridge already disposed"). The C++ callers handle this
  # reactively — catch DisposedException and retry — and so do we.
  @max_retries 5
  @retry_interval_ms 50
  @bridge_disposed "bridge already disposed"

  @doc """
  Start a connection pool.

  ## Options

    * `:name`      — process name (required)
    * `:host`      — soffice hostname (default `"localhost"`)
    * `:port`      — soffice URP listener port (default `2002`)
    * `:pool_size` — number of connections (default `1`). Increase when
      running multiple soffice replicas behind a load balancer.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop!(opts, :name)
    {pool_size, opts} = Keyword.pop(opts, :pool_size, 1)

    NimblePool.start_link(
      worker: {__MODULE__, Map.new(opts)},
      pool_size: pool_size,
      name: name
    )
  end

  @doc false
  def child_spec(opts) do
    %{
      id: Keyword.fetch!(opts, :name),
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
  def convert_stream(pool, input_bytes, opts \\ [])
      when is_binary(input_bytes) do
    {timeout, opts} = Keyword.pop(opts, :timeout, @default_timeout)
    store_opts = Keyword.take(opts, [:filter, :sink])

    do_checkout(pool, timeout, fn conn ->
      doc = Bridge.load_document_stream!(conn, input_bytes)
      result = Bridge.store_to_stream!(conn, doc, store_opts)
      {wrap_result(result), :closed}
    end)
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
  def convert_file_stream(pool, input_path, opts \\ [])
      when is_binary(input_path) do
    {timeout, opts} = Keyword.pop(opts, :timeout, @default_timeout)
    store_opts = Keyword.take(opts, [:filter, :sink])

    do_checkout(pool, timeout, fn conn ->
      doc = Bridge.load_document_file_stream!(conn, input_path)
      result = Bridge.store_to_stream!(conn, doc, store_opts)
      {wrap_result(result), :closed}
    end)
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
  def convert(pool, input_path, output_path \\ nil, opts \\ []) do
    {timeout, opts} = Keyword.pop(opts, :timeout, @default_timeout)
    output_path = output_path || Path.rootname(input_path) <> ".pdf"
    filter = Keyword.get(opts, :filter, "writer_pdf_Export")
    in_url = "file://" <> Path.expand(input_path)
    out_url = "file://" <> Path.expand(output_path)

    do_checkout(pool, timeout, fn conn ->
      doc = Bridge.load_document!(conn, in_url)
      Bridge.store_to_url!(conn, doc, out_url, filter)
      Bridge.close_document!(conn, doc)
      {{:ok, output_path}, {:ok, conn}}
    end)
  end

  defp do_checkout(pool, timeout, fun, attempt \\ 1) do
    result =
      NimblePool.checkout!(
        pool,
        :checkout,
        fn _from, conn ->
          try do
            fun.(conn)
          rescue
            e -> {{:error, Exception.message(e)}, :closed}
          end
        end,
        timeout
      )

    case result do
      {:error, msg} when is_binary(msg) and attempt < @max_retries ->
        if String.contains?(msg, @bridge_disposed) do
          Process.sleep(@retry_interval_ms * attempt)
          do_checkout(pool, timeout, fun, attempt + 1)
        else
          result
        end

      _ ->
        result
    end
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
    conn = open_with_retry(host, port)
    {:ok, conn, config}
  end

  defp open_with_retry(host, port, attempt \\ 1) do
    Bridge.open!(host, port)
  rescue
    e ->
      if attempt < @max_retries do
        Process.sleep(@retry_interval_ms * attempt)
        open_with_retry(host, port, attempt + 1)
      else
        reraise e, __STACKTRACE__
      end
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

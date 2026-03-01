defmodule URP.Pool do
  @moduledoc false

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

  @doc false
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

  @doc false
  @spec version(NimblePool.pool(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def version(pool, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    do_checkout(pool, timeout, fn conn ->
      {{:ok, Bridge.version!(conn)}, {:ok, conn}}
    end)
  end

  @doc false
  @spec convert(NimblePool.pool(), binary() | {:binary, binary()} | Enumerable.t(), keyword()) ::
          {:ok, binary()} | :ok | {:error, String.t()}
  def convert(pool, input, opts \\ []) do
    {timeout, opts} = Keyword.pop(opts, :timeout, @default_timeout)
    store_opts = Keyword.take(opts, [:filter, :sink])

    do_checkout(pool, timeout, fn conn ->
      doc = load_input!(conn, input)
      result = Bridge.store_to_stream!(conn, doc, store_opts)
      close_status = safe_close(conn, doc)
      URP.Stream.clear_input_ctx()

      case close_status do
        :ok -> {wrap_result(result), {:ok, conn}}
        :closed -> {wrap_result(result), :closed}
      end
    end)
  end

  defp load_input!(conn, path) when is_binary(path),
    do: Bridge.load_document_file_stream!(conn, path)

  defp load_input!(conn, {:binary, bytes}) when is_binary(bytes),
    do: Bridge.load_document_stream!(conn, bytes)

  defp load_input!(conn, enumerable),
    do: Bridge.load_document_enum_stream!(conn, enumerable)

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

  defp safe_close(conn, doc) do
    Bridge.close_document!(conn, doc)
    :ok
  rescue
    _ -> :closed
  end

  defp wrap_result(:ok), do: :ok
  defp wrap_result(bytes) when is_binary(bytes), do: {:ok, bytes}
end

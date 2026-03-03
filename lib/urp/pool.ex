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
      conn = Bridge.version(conn)

      if conn.last_error do
        {{:error, conn.last_error}, {:ok, %{conn | last_error: nil}}}
      else
        {{:ok, conn.private.version}, {:ok, conn}}
      end
    end)
  end

  @doc false
  @spec services(NimblePool.pool(), keyword()) :: {:ok, [String.t()]} | {:error, String.t()}
  def services(pool, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    do_checkout(pool, timeout, fn conn ->
      conn = Bridge.services(conn)

      if conn.last_error do
        {{:error, conn.last_error}, {:ok, %{conn | last_error: nil}}}
      else
        {{:ok, conn.private.services}, {:ok, conn}}
      end
    end)
  end

  @doc false
  @spec filters(NimblePool.pool(), keyword()) :: {:ok, [String.t()]} | {:error, String.t()}
  def filters(pool, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    do_checkout(pool, timeout, fn conn ->
      conn = Bridge.filters(conn)

      if conn.last_error do
        {{:error, conn.last_error}, {:ok, %{conn | last_error: nil}}}
      else
        {{:ok, conn.private.filters}, {:ok, conn}}
      end
    end)
  end

  @doc false
  @spec types(NimblePool.pool(), keyword()) :: {:ok, [String.t()]} | {:error, String.t()}
  def types(pool, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    do_checkout(pool, timeout, fn conn ->
      conn = Bridge.types(conn)

      if conn.last_error do
        {{:error, conn.last_error}, {:ok, %{conn | last_error: nil}}}
      else
        {{:ok, conn.private.types}, {:ok, conn}}
      end
    end)
  end

  @doc false
  @spec locale(NimblePool.pool(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def locale(pool, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    do_checkout(pool, timeout, fn conn ->
      conn = Bridge.locale(conn)

      if conn.last_error do
        {{:error, conn.last_error}, {:ok, %{conn | last_error: nil}}}
      else
        {{:ok, conn.private.locale}, {:ok, conn}}
      end
    end)
  end

  @doc false
  @spec convert(NimblePool.pool(), binary() | {:binary, binary()} | Enumerable.t(), keyword()) ::
          {:ok, binary()} | :ok | {:error, String.t()}
  def convert(pool, input, opts \\ []) do
    {timeout, opts} = Keyword.pop(opts, :timeout, @default_timeout)
    {sink, opts} = Keyword.pop(opts, :sink)
    store_opts = Keyword.take(opts, [:filter, :filter_data])

    do_checkout(pool, timeout, fn conn ->
      conn = load_input(conn, input)
      {bytes, conn} = Bridge.store_document_write(conn, store_opts)
      result = if bytes, do: apply_sink(bytes, sink)
      conn = Bridge.close_document(conn)
      conn = safe_cleanup(conn)
      Process.delete(:urp_tid_cache)

      if conn.last_error do
        {{:error, conn.last_error}, :closed}
      else
        {wrap_result(result), {:ok, reset_conversion_state(conn)}}
      end
    end)
  end

  defp load_input(conn, {:binary, bytes}) when is_binary(bytes) do
    Bridge.load_document_write(conn, bytes)
  end

  defp load_input(conn, path) when is_binary(path) do
    Bridge.load_document_write(conn, File.read!(path))
  end

  defp load_input(conn, enumerable) do
    Bridge.load_document_enum_stream(conn, enumerable)
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
            e in [RuntimeError, MatchError, File.Error] ->
              {{:error, Exception.message(e)}, :closed}
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
    e in [MatchError, RuntimeError] ->
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
  def terminate_worker(_reason, %Bridge{} = conn, pool_state) do
    Bridge.close!(conn)
    {:ok, pool_state}
  end

  def terminate_worker(_reason, _conn, pool_state) do
    {:ok, pool_state}
  end

  defp apply_sink(bytes, nil), do: bytes

  defp apply_sink(bytes, {:path, path}) do
    File.write!(path, bytes)
    :ok
  end

  defp apply_sink(bytes, fun) when is_function(fun, 1) do
    fun.(bytes)
    :ok
  end

  defp safe_cleanup(%{cleanup_url: nil} = conn), do: conn
  defp safe_cleanup(conn), do: Bridge.delete_file(conn, conn.cleanup_url)

  defp reset_conversion_state(conn) do
    %{
      conn
      | doc_oid: nil,
        cleanup_url: nil,
        input_ctx: nil,
        reply_tid: nil,
        reader_type: nil,
        last_error: nil
    }
  end

  defp wrap_result(:ok), do: :ok
  defp wrap_result(bytes) when is_binary(bytes), do: {:ok, bytes}
end

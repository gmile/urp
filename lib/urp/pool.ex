defmodule URP.Pool do
  @moduledoc false

  @behaviour NimblePool

  alias URP.Bridge

  require Logger

  @default_timeout 120_000
  @default_backoff_initial 500
  @default_backoff_max 5_000

  # soffice's URP bridge transitions to STATE_TERMINATED when a connection
  # closes, revoking stubs from the UNO environment. If we reconnect before
  # that cleanup finishes, the new bridge may throw DisposedException
  # ("Binary URP bridge already disposed"). The C++ callers handle this
  # reactively — catch DisposedException and retry — and so do we.
  @disposed_max_retries 5
  @disposed_retry_interval_ms 50
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
  def version(pool, opts \\ []), do: query(pool, opts, &Bridge.version/1, :version)

  @doc false
  @spec services(NimblePool.pool(), keyword()) :: {:ok, [String.t()]} | {:error, String.t()}
  def services(pool, opts \\ []), do: query(pool, opts, &Bridge.services/1, :services)

  @doc false
  @spec filters(NimblePool.pool(), keyword()) :: {:ok, [String.t()]} | {:error, String.t()}
  def filters(pool, opts \\ []), do: query(pool, opts, &Bridge.filters/1, :filters)

  @doc false
  @spec types(NimblePool.pool(), keyword()) :: {:ok, [String.t()]} | {:error, String.t()}
  def types(pool, opts \\ []), do: query(pool, opts, &Bridge.types/1, :types)

  @doc false
  @spec locale(NimblePool.pool(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def locale(pool, opts \\ []), do: query(pool, opts, &Bridge.locale/1, :locale)

  defp query(pool, opts, bridge_fun, key) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    meta = %{operation: key, pool: pool}

    do_checkout(pool, timeout, meta, fn conn ->
      conn = bridge_fun.(conn)

      if is_nil(conn.error) do
        {{:ok, conn.private[key]}, {:ok, conn}}
      else
        {{:error, conn.error}, {:ok, %{conn | error: nil}}}
      end
    end)
  end

  @doc false
  @spec convert(NimblePool.pool(), binary() | {:binary, binary()} | Enumerable.t(), keyword()) ::
          {:ok, binary()} | :ok | {:error, String.t()}
  def convert(pool, input, opts \\ []) do
    {timeout, opts} = Keyword.pop(opts, :timeout, @default_timeout)
    {sink, opts} = Keyword.pop(opts, :sink)
    {settings, opts} = Keyword.pop(opts, :settings, [])
    {max_frame_size, opts} = Keyword.pop(opts, :max_frame_size)
    {recv_timeout, opts} = Keyword.pop(opts, :recv_timeout)
    store_opts = Keyword.take(opts, [:filter, :filter_data])

    meta = %{operation: :convert, pool: pool}

    do_checkout(pool, timeout, meta, fn conn ->
      conn = if max_frame_size, do: %{conn | max_frame_size: max_frame_size}, else: conn
      conn = if recv_timeout, do: %{conn | recv_timeout: recv_timeout}, else: conn

      conn =
        conn
        |> Bridge.apply_settings(settings)
        |> load_input(input)
        |> Bridge.store_document_write(store_opts)

      result = if conn.reply, do: apply_sink(conn.reply, sink)
      conn = Bridge.close_document(conn)
      conn = safe_cleanup(conn)
      Process.delete(:urp_tid_cache)

      if is_nil(conn.error) do
        {wrap_result(result), {:ok, reset_conversion_state(conn)}}
      else
        {{:error, conn.error}, :closed}
      end
    end)
  end

  defp load_input(conn, {:binary, bytes}) when is_binary(bytes) do
    Bridge.load_document_write(conn, bytes)
  end

  defp load_input(conn, path) when is_binary(path) do
    case File.read(path) do
      {:ok, bytes} ->
        Bridge.load_document_write(conn, bytes)

      {:error, reason} ->
        %{conn | error: "could not read file #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp load_input(conn, enumerable) do
    Bridge.load_document_enum_stream(conn, enumerable)
  end

  defp do_checkout(pool, timeout, meta, fun, attempt \\ 1) do
    t0 = System.monotonic_time()

    result =
      NimblePool.checkout!(
        pool,
        :checkout,
        fn _from, conn ->
          t1 = System.monotonic_time()
          {result, checkin} = fun.(conn)
          t2 = System.monotonic_time()

          :telemetry.execute(
            [:urp, :call, :stop],
            %{
              total_time: t2 - t0,
              queue_time: t1 - t0,
              service_time: t2 - t1
            },
            Map.put(meta, :result, result_tag(result))
          )

          {result, checkin}
        end,
        timeout
      )

    case result do
      {:error, message} when is_binary(message) and attempt < @disposed_max_retries ->
        if String.contains?(message, @bridge_disposed) do
          Process.sleep(@disposed_retry_interval_ms * attempt)
          do_checkout(pool, timeout, meta, fun, attempt + 1)
        else
          result
        end

      _ ->
        result
    end
  end

  defp result_tag({:error, _}), do: :error
  defp result_tag(_), do: :ok

  ## NimblePool callbacks

  @impl NimblePool
  def init_pool(config) do
    {:ok, config}
  end

  @impl NimblePool
  def init_worker(config) do
    host = Map.get(config, :host, "localhost")
    port = Map.get(config, :port, 2002)
    backoff_initial = Map.get(config, :backoff_initial, @default_backoff_initial)
    backoff_max = Map.get(config, :backoff_max, @default_backoff_max)

    # Use {:async, ...} so start_link returns immediately even if soffice is
    # down and open_with_retry loops for a while. We must transfer socket
    # ownership to the NimblePool process — the Task that runs this function
    # exits after returning, which would close the socket otherwise.
    pool_pid = self()

    {:async,
     fn ->
       conn = open_with_retry(host, port, backoff_initial, backoff_max)
       if conn.sock, do: :gen_tcp.controlling_process(conn.sock, pool_pid)
       conn
     end, config}
  end

  defp open_with_retry(host, port, backoff_initial, backoff_max, attempt \\ 1) do
    conn = Bridge.open(host, port)

    cond do
      is_nil(conn.error) ->
        conn

      is_nil(conn.sock) ->
        # TCP or handshake failed — soffice unreachable. Retry with backoff.
        delay = min(backoff_initial * Integer.pow(2, attempt - 1), backoff_max)

        :telemetry.execute(
          [:urp, :connection, :retry],
          %{attempt: attempt, delay: delay},
          %{host: host, port: port, reason: conn.error}
        )

        Logger.warning(
          "URP connection failed (attempt #{attempt}, retry in #{delay}ms): #{conn.error}",
          host: host,
          port: port
        )

        Process.sleep(delay)
        open_with_retry(host, port, backoff_initial, backoff_max, attempt + 1)

      true ->
        # Connected but bootstrap failed — don't retry forever.
        Bridge.close!(conn)
        %{conn | sock: nil}
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
        reply: nil,
        error: nil
    }
  end

  defp wrap_result(:ok), do: :ok
  defp wrap_result(bytes) when is_binary(bytes), do: {:ok, bytes}
end

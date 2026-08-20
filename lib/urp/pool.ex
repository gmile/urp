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
      worker: {__MODULE__, opts},
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
  @spec version(NimblePool.pool(), keyword()) :: {:ok, String.t()} | {:error, URP.error()}
  def version(pool, opts \\ []), do: query(pool, opts, &Bridge.version/1, :version)

  @doc false
  @spec services(NimblePool.pool(), keyword()) :: {:ok, [String.t()]} | {:error, URP.error()}
  def services(pool, opts \\ []), do: query(pool, opts, &Bridge.services/1, :services)

  @doc false
  @spec filters(NimblePool.pool(), keyword()) :: {:ok, [String.t()]} | {:error, URP.error()}
  def filters(pool, opts \\ []), do: query(pool, opts, &Bridge.filters/1, :filters)

  @doc false
  @spec types(NimblePool.pool(), keyword()) :: {:ok, [String.t()]} | {:error, URP.error()}
  def types(pool, opts \\ []), do: query(pool, opts, &Bridge.types/1, :types)

  @doc false
  @spec locale(NimblePool.pool(), keyword()) :: {:ok, String.t()} | {:error, URP.error()}
  def locale(pool, opts \\ []), do: query(pool, opts, &Bridge.locale/1, :locale)

  defp query(pool, opts, bridge_fun, key) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    meta = %{operation: key, pool: pool}

    do_checkout(pool, timeout, meta, fn conn ->
      conn = bridge_fun.(conn)

      if is_nil(conn.error) do
        {{:ok, conn.private[key]}, {:ok, reset_conversion_state(conn)}}
      else
        {{:error, conn.error}, :closed}
      end
    end)
  end

  @doc false
  @spec convert(NimblePool.pool(), binary() | {:binary, binary()} | Enumerable.t(), keyword()) ::
          {:ok, binary()} | :ok | {:error, URP.error()}
  def convert(pool, input, opts \\ []) do
    {timeout, opts} = Keyword.pop(opts, :timeout, @default_timeout)
    {sink, opts} = Keyword.pop(opts, :sink)
    {settings, opts} = Keyword.pop(opts, :settings, [])
    {max_frame_size, opts} = Keyword.pop(opts, :max_frame_size)
    {recv_timeout, opts} = Keyword.pop(opts, :recv_timeout)
    {io_raw, opts} = Keyword.pop(opts, :io, :file)
    {io_in, io_out} = normalize_io(io_raw)
    store_opts = Keyword.take(opts, [:filter, :filter_data])

    meta = %{operation: :convert, pool: pool}
    stream_input? = io_in == :stream or enumerable_input?(input)

    do_checkout(pool, timeout, meta, fn conn ->
      default_max_frame_size = conn.max_frame_size
      default_recv_timeout = conn.recv_timeout

      # Clear stale reply from bootstrap (desktop OID) on the first conversion.
      # Subsequent conversions are already clean via reset_conversion_state.
      conn = %{conn | reply: nil}
      conn = if max_frame_size, do: %{conn | max_frame_size: max_frame_size}, else: conn
      conn = if recv_timeout, do: %{conn | recv_timeout: recv_timeout}, else: conn

      conn =
        conn
        |> Bridge.apply_settings(settings)
        |> load_input(input, io_in)
        |> store_output(store_opts, sink, io_out)

      # Bridge.cleanup/1 only ever appends to conn.error, so this is the last
      # point at which we can tell a failed conversion from a failed cleanup.
      convert_error = conn.error
      result = conn.reply
      conn = Bridge.cleanup(conn)
      conn = %{conn | max_frame_size: default_max_frame_size, recv_timeout: default_recv_timeout}

      case checkout_outcome(result, convert_error, conn.error, stream_input?) do
        {value, :reuse} -> {value, {:ok, reset_conversion_state(conn)}}
        {value, :discard} -> {value, :closed}
      end
    end)
  end

  @doc false
  @spec checkout_outcome(term(), URP.error() | nil, URP.error() | nil, boolean()) ::
          {:ok | {:ok, binary()} | {:error, URP.error()}, :reuse | :discard}
  def checkout_outcome(result, convert_error, error, stream_input?) do
    # Stream-based input registers an XInputStream at a fixed OID cache slot.
    # soffice's URP cache doesn't fully reset on reuse, producing truncated
    # documents on subsequent stream loads. Discard the connection to force
    # a fresh handshake. File-based I/O reuses connections normally.
    reusable = not stream_input? and is_nil(error)

    # A socket-level failure leaves conn.reply holding whatever the last call
    # parsed — typically an interface OID — so the shape of the reply alone
    # cannot tell output from leftovers. Only trust it if the conversion itself
    # reported no error.
    has_result = is_nil(convert_error) and (is_binary(result) or result == :ok)

    cond do
      reusable ->
        {wrap_result(result), :reuse}

      has_result ->
        # Conversion succeeded but close/cleanup failed (e.g. soffice drops
        # the connection after stream→stream). Return the result, discard conn.
        {wrap_result(result), :discard}

      true ->
        {{:error, error}, :discard}
    end
  end

  defp normalize_io(:file), do: {:file, :file}
  defp normalize_io(:stream), do: {:stream, :stream}

  defp normalize_io({in_mode, out_mode})
       when in_mode in [:file, :stream] and out_mode in [:file, :stream],
       do: {in_mode, out_mode}

  defp normalize_io(other) do
    raise ArgumentError,
          ":io must be :file, :stream, or {:file | :stream, :file | :stream}; got: #{inspect(other)}"
  end

  defp enumerable_input?({:binary, bytes}) when is_binary(bytes), do: false
  defp enumerable_input?(path) when is_binary(path), do: false
  defp enumerable_input?(_input), do: true

  ## Input routing

  defp load_input(conn, {:binary, bytes}, :file) when is_binary(bytes) do
    Bridge.load_document_write(conn, bytes)
  end

  defp load_input(conn, {:binary, bytes}, :stream) when is_binary(bytes) do
    Bridge.load_document_stream(conn, bytes)
  end

  defp load_input(conn, path, :file) when is_binary(path) do
    case File.read(path) do
      {:ok, bytes} ->
        Bridge.load_document_write(conn, bytes)

      {:error, reason} ->
        %{conn | error: "could not read file #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp load_input(conn, path, :stream) when is_binary(path) do
    Bridge.load_document_file_stream(conn, path)
  end

  defp load_input(conn, enumerable, _io_mode) do
    Bridge.load_document_enum_stream(conn, enumerable)
  end

  ## Output routing

  defp store_output(%{error: e} = conn, _store_opts, _sink, _io_mode) when not is_nil(e),
    do: conn

  defp store_output(conn, store_opts, sink, :file) do
    conn = Bridge.store_document_write(conn, store_opts)

    if conn.error do
      conn
    else
      case apply_sink(conn.reply, sink) do
        {:ok, result} -> %{conn | reply: result}
        {:error, message} -> %{conn | error: message, reply: nil}
      end
    end
  end

  defp store_output(conn, store_opts, sink, :stream) do
    stream_opts = if sink, do: [{:sink, sink} | store_opts], else: store_opts
    Bridge.store_to_stream(conn, stream_opts)
  end

  defp do_checkout(pool, timeout, meta, fun, attempt \\ 1) do
    t0 = System.monotonic_time()
    :telemetry.execute([:urp, :call, :start], %{system_time: System.system_time()}, meta)

    try do
      {result, queue_time, service_time, attempts} =
        do_checkout_attempt(pool, timeout, fun, attempt, 0, 0)

      total_time = System.monotonic_time() - t0

      :telemetry.execute(
        [:urp, :call, :stop],
        %{
          total_time: total_time,
          queue_time: queue_time,
          service_time: service_time,
          backoff_time: max(total_time - queue_time - service_time, 0)
        },
        meta |> Map.put(:result, result_tag(result)) |> Map.put(:attempts, attempts)
      )

      result
    catch
      kind, reason ->
        stacktrace = __STACKTRACE__

        :telemetry.execute(
          [:urp, :call, :exception],
          %{duration: System.monotonic_time() - t0},
          Map.merge(meta, %{kind: kind, reason: reason, stacktrace: stacktrace})
        )

        case kind do
          :exit -> {:error, "pool checkout failed: #{Exception.format_exit(reason)}"}
          _ -> :erlang.raise(kind, reason, stacktrace)
        end
    end
  end

  defp do_checkout_attempt(pool, timeout, fun, attempt, queue_acc, service_acc) do
    attempt_started = System.monotonic_time()

    {result, queue_time, service_time} =
      NimblePool.checkout!(
        pool,
        :checkout,
        fn _from, conn ->
          checked_out = System.monotonic_time()

          {result, checkin} =
            with_protocol_caches(conn, fn ->
              fun.(conn)
            end)

          finished = System.monotonic_time()
          {{result, checked_out - attempt_started, finished - checked_out}, checkin}
        end,
        timeout
      )

    queue_acc = queue_acc + queue_time
    service_acc = service_acc + service_time

    if disposed_error?(result) and attempt < @disposed_max_retries do
      Process.sleep(@disposed_retry_interval_ms * attempt)
      do_checkout_attempt(pool, timeout, fun, attempt + 1, queue_acc, service_acc)
    else
      {result, queue_acc, service_acc, attempt}
    end
  end

  defp disposed_error?({:error, message}) when is_binary(message),
    do: String.contains?(message, @bridge_disposed)

  defp disposed_error?(_result), do: false

  defp with_protocol_caches(conn, fun) do
    missing = make_ref()
    previous_tid = Process.get(:urp_tid_cache, missing)
    previous_oid = Process.get(:urp_oid_cache, missing)
    Process.put(:urp_tid_cache, conn.tid_cache)
    Process.put(:urp_oid_cache, conn.oid_cache)

    try do
      {result, checkin} = fun.()
      tid_cache = Process.get(:urp_tid_cache, %{})
      oid_cache = Process.get(:urp_oid_cache, %{})
      {result, persist_protocol_caches(checkin, tid_cache, oid_cache)}
    after
      restore_process_value(:urp_tid_cache, previous_tid, missing)
      restore_process_value(:urp_oid_cache, previous_oid, missing)
    end
  end

  defp persist_protocol_caches({:ok, conn}, tid_cache, oid_cache),
    do: {:ok, %{conn | tid_cache: tid_cache, oid_cache: oid_cache}}

  defp persist_protocol_caches(checkin, _tid_cache, _oid_cache), do: checkin

  defp restore_process_value(key, missing, missing), do: Process.delete(key)
  defp restore_process_value(key, value, _missing), do: Process.put(key, value)

  defp result_tag({:error, _}), do: :error
  defp result_tag(_), do: :ok

  ## NimblePool callbacks

  @impl NimblePool
  def init_pool(config) do
    {:ok, config}
  end

  @impl NimblePool
  def init_worker(config) do
    host = Keyword.get(config, :host, "localhost")
    port = Keyword.get(config, :port, 2002)
    backoff_initial = Keyword.get(config, :backoff_initial, @default_backoff_initial)
    backoff_max = Keyword.get(config, :backoff_max, @default_backoff_max)
    bridge_opts = Keyword.take(config, [:connect_timeout, :send_timeout])

    # Use {:async, ...} so start_link returns immediately even if soffice is
    # down and open_with_retry loops for a while. We must transfer socket
    # ownership to the NimblePool process — the Task that runs this function
    # exits after returning, which would close the socket otherwise.
    pool_pid = self()

    {:async,
     fn ->
       conn = open_with_retry(host, port, backoff_initial, backoff_max, bridge_opts)
       if conn.sock, do: :gen_tcp.controlling_process(conn.sock, pool_pid)
       conn
     end, config}
  end

  defp open_with_retry(host, port, backoff_initial, backoff_max, bridge_opts, attempt \\ 1) do
    conn = Bridge.open(host, port, bridge_opts)

    cond do
      is_nil(conn.error) ->
        conn

      is_nil(conn.sock) ->
        # TCP or handshake failed — soffice unreachable. Retry with backoff.
        delay = backoff_delay(backoff_initial, backoff_max, attempt)

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
        open_with_retry(host, port, backoff_initial, backoff_max, bridge_opts, attempt + 1)

      true ->
        # Connected but bootstrap failed — don't retry forever.
        Bridge.close!(conn)
        %{conn | sock: nil}
    end
  end

  defp backoff_delay(initial, maximum, attempt) do
    capped_attempt = min(attempt - 1, 30)
    min(initial * Integer.pow(2, capped_attempt), maximum)
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

  defp apply_sink(bytes, nil), do: {:ok, bytes}

  defp apply_sink(bytes, {:path, path}) do
    case File.write(path, bytes) do
      :ok ->
        {:ok, :ok}

      {:error, reason} ->
        {:error, "could not write output #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp apply_sink(bytes, fun) when is_function(fun, 1) do
    try do
      fun.(bytes)
      {:ok, :ok}
    rescue
      error -> {:error, "output sink failed: #{Exception.message(error)}"}
    end
  end

  defp reset_conversion_state(conn) do
    %{
      conn
      | doc_oid: nil,
        cleanup_url: nil,
        input_ctx: nil,
        reply_tid: nil,
        reader_type: nil,
        reply: nil,
        error: nil,
        private: %{}
    }
  end

  defp wrap_result(:ok), do: :ok
  defp wrap_result(bytes) when is_binary(bytes), do: {:ok, bytes}
end

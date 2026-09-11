defmodule URP.PoolReconnectTest do
  use ExUnit.Case, async: false

  @moduletag timeout: 30_000

  @handler_id "pool-reconnect-test-handler"

  def handle_event(event, measurements, metadata, test_pid) do
    send(test_pid, {:telemetry_event, event, measurements, metadata})
  end

  setup do
    Application.ensure_all_started(:telemetry)
    Application.ensure_all_started(:nimble_pool)

    :telemetry.attach(
      @handler_id,
      [:urp, :connection, :retry],
      &__MODULE__.handle_event/4,
      self()
    )

    on_exit(fn -> :telemetry.detach(@handler_id) end)
  end

  defp unused_port! do
    {:ok, listen} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(listen)
    :gen_tcp.close(listen)
    port
  end

  test "pool retries forever until soffice comes back" do
    port = unused_port!()

    pool =
      start_supervised!(
        {URP.Pool,
         name: :"reconnect_test_#{System.unique_integer([:positive])}",
         host: "localhost",
         port: port,
         pool_size: 1,
         backoff_initial: 10,
         backoff_max: 100}
      )

    assert_receive {:telemetry_event, [:urp, :connection, :retry], %{attempt: 1, delay: _}, _},
                   5_000

    assert_receive {:telemetry_event, [:urp, :connection, :retry], %{attempt: 2, delay: _}, _},
                   5_000

    assert Process.alive?(pool)
  end

  test "backoff is capped at backoff_max" do
    port = unused_port!()

    _pool =
      start_supervised!(
        {URP.Pool,
         name: :"backoff_cap_test_#{System.unique_integer([:positive])}",
         host: "localhost",
         port: port,
         pool_size: 1,
         backoff_initial: 10,
         backoff_max: 30}
      )

    assert_receive {:telemetry_event, [:urp, :connection, :retry], %{attempt: 1, delay: 10}, _},
                   5_000

    assert_receive {:telemetry_event, [:urp, :connection, :retry], %{attempt: 2, delay: 20}, _},
                   5_000

    assert_receive {:telemetry_event, [:urp, :connection, :retry], %{attempt: 3, delay: 30}, _},
                   5_000
  end

  test "a pool spreads its workers over every address the host resolves to" do
    lookup = :inet_db.res_option(:lookup)
    :inet_db.set_lookup([:file | lookup])
    :inet_db.add_host({127, 0, 0, 1}, [~c"soffice-pair"])
    :inet_db.add_host({127, 0, 0, 2}, [~c"soffice-pair"])

    on_exit(fn ->
      :inet_db.del_host({127, 0, 0, 1})
      :inet_db.del_host({127, 0, 0, 2})
      :inet_db.set_lookup(lookup)
    end)

    port = unused_port!()

    start_supervised!(
      {URP.Pool,
       name: :"spread_test_#{System.unique_integer([:positive])}",
       host: "soffice-pair",
       port: port,
       pool_size: 2,
       connect_timeout: 300,
       backoff_initial: 10,
       backoff_max: 100}
    )

    assert_receive {:telemetry_event, [:urp, :connection, :retry], %{attempt: 1},
                    %{address: first}},
                   5_000

    assert_receive {:telemetry_event, [:urp, :connection, :retry], %{attempt: 1},
                    %{address: second}},
                   5_000

    assert Enum.sort([first, second]) == ["127.0.0.1", "127.0.0.2"]
  end

  test "checkout timeout returns an error and emits start plus exception" do
    port = unused_port!()
    pool_name = :checkout_timeout_test
    handler_id = "#{@handler_id}-call-span"

    :telemetry.attach_many(
      handler_id,
      [[:urp, :call, :start], [:urp, :call, :exception]],
      &__MODULE__.handle_event/4,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    _pool =
      start_supervised!(
        {URP.Pool,
         name: pool_name,
         host: "localhost",
         port: port,
         pool_size: 1,
         backoff_initial: 10,
         backoff_max: 30}
      )

    assert {:error, message} = URP.Pool.version(pool_name, timeout: 20)
    assert message =~ "pool checkout failed"

    assert_receive {:telemetry_event, [:urp, :call, :start], %{system_time: system_time},
                    metadata}

    assert is_integer(system_time)
    assert metadata.operation == :version

    assert_receive {:telemetry_event, [:urp, :call, :exception], %{duration: duration}, metadata}
    assert duration > 0
    assert metadata.kind == :exit
  end
end

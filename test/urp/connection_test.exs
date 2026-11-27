defmodule URP.ConnectionTest do
  use ExUnit.Case, async: false

  alias URP.Protocol, as: P
  alias URP.{Bridge, Connection, Pool}

  # A soffice that speaks just enough URP to connect to and ask for its
  # services, and that misbehaves on request: `script` says what to do with
  # each such ask, in order, and then it answers.
  defmodule FakeSoffice do
    @interface "com.sun.star.uno.XInterface"

    def start(script, opts \\ []) do
      {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
      {:ok, port} = :inet.port(listen)
      {:ok, script} = Agent.start_link(fn -> script end)
      oid = Keyword.get_lazy(opts, :oid, fn -> "fake-#{System.unique_integer([:positive])}" end)
      on_call = Keyword.get(opts, :on_call)
      spawn_link(fn -> accept(listen, script, oid, on_call) end)
      port
    end

    defp accept(listen, script, oid, on_call) do
      {:ok, sock} = :gen_tcp.accept(listen)

      spawn_link(fn ->
        try do
          handshake(sock)
          serve(sock, script, oid, on_call)
        rescue
          URP.SocketError -> :ok
        end
      end)

      accept(listen, script, oid, on_call)
    end

    defp handshake(sock) do
      header =
        P.header(4, "com.sun.star.bridge.XProtocolProperties", "UrpProtocolProperties", "tid")

      P.send_frame(sock, [header, <<1::32>>])
      P.recv_frame(sock, 1_000)
      P.send_frame(sock, <<0x80, 0::32>>)
      P.recv_frame(sock, 1_000)
      P.send_frame(sock, <<5>>)
      P.recv_frame(sock, 1_000)
    end

    # Our requests carry the function in their second byte. queryInterface (0)
    # is answered with an object in an any, the calls that make objects (3, 4)
    # with an object, and the ask for services (5) as the script says.
    defp serve(sock, script, oid, on_call) do
      case P.recv_frame(sock, 5_000) do
        <<_flags, 0, _::binary>> ->
          reply(sock, P.encode(:any, {{:interface, @interface}, oid}))

        <<_flags, function, _::binary>> when function in [3, 4] ->
          reply(sock, P.encode({:interface, @interface}, oid))

        <<_flags, 5, _::binary>> ->
          if on_call, do: on_call.(:start, oid)
          services = P.encode({:sequence, :string}, ["a", "b"])

          case Agent.get_and_update(script, &List.pop_at(&1, 0)) do
            nil ->
              if on_call, do: on_call.(:stop, oid)
              reply(sock, services)

            {:after, ms} ->
              Process.sleep(ms)
              if on_call, do: on_call.(:stop, oid)
              reply(sock, services)

            :answer_then_hang_up ->
              if on_call, do: on_call.(:stop, oid)
              reply(sock, services)
              :gen_tcp.close(sock)

            :hang_up ->
              if on_call, do: on_call.(:stop, oid)
              :gen_tcp.close(sock)

            :say_nothing ->
              Process.sleep(2_000)
              if on_call, do: on_call.(:stop, oid)
          end
      end

      serve(sock, script, oid, on_call)
    end

    defp reply(sock, body), do: P.send_frame(sock, [<<0x80>>, body])
  end

  defp start_pool(script, opts \\ []) do
    name = :"connection_test_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Pool,
       [name: name, host: "127.0.0.1", port: FakeSoffice.start(script), backoff_initial: 10] ++
         opts}
    )

    name
  end

  defp services(pool, opts \\ []), do: Pool.run(pool, :services, opts, &Bridge.services/1)

  def drained(_event, _measurements, meta, test), do: send(test, {:drain, meta.result})

  describe "a connection" do
    test "runs a job" do
      assert services(start_pool([])) == {:ok, ["a", "b"]}
    end

    test "reconnects after soffice hangs up on a job, which fails" do
      pool = start_pool([:hang_up])

      assert services(pool) == {:error, :closed}
      assert services(pool) == {:ok, ["a", "b"]}
    end

    test "reconnects before a job if soffice hung up while it was idle" do
      pool = start_pool([:answer_then_hang_up])

      assert services(pool) == {:ok, ["a", "b"]}
      Process.sleep(50)
      assert services(pool) == {:ok, ["a", "b"]}
    end

    test "gives up on a soffice that says nothing for drain_timeout, and reconnects" do
      :telemetry.attach(
        "connection-test",
        [:urp, :connection, :drain],
        &__MODULE__.drained/4,
        self()
      )

      on_exit(fn -> :telemetry.detach("connection-test") end)
      pool = start_pool([:say_nothing], drain_timeout: 200)

      assert services(pool, timeout: 50) == {:error, :timeout}
      assert_receive {:drain, {:error, :timeout}}, 1_000
      assert services(pool) == {:ok, ["a", "b"]}
    end

    test "finishes the job in hand when its pool is stopped" do
      pool = start_pool(after: 200)
      job = Task.async(fn -> services(pool) end)
      Process.sleep(50)

      stop_supervised!(Pool)

      assert Task.await(job) == {:ok, ["a", "b"]}
    end

    test "serializes jobs across multiple connections to the same soffice" do
      {:ok, tracker} = Agent.start_link(fn -> %{active: 0, max: 0} end)

      on_call = fn
        :start, _oid ->
          Agent.update(tracker, fn %{active: a, max: m} ->
            %{active: a + 1, max: max(m, a + 1)}
          end)

        :stop, _oid ->
          Agent.update(tracker, &%{&1 | active: &1.active - 1})
      end

      port = FakeSoffice.start(List.duplicate({:after, 60}, 6), on_call: on_call)
      pool_a = :"serial_a_#{System.unique_integer([:positive])}"
      pool_b = :"serial_b_#{System.unique_integer([:positive])}"

      start_supervised!(
        Supervisor.child_spec(
          {Pool, name: pool_a, host: "127.0.0.1", port: port, pool_size: 3, backoff_initial: 10},
          id: pool_a
        )
      )

      start_supervised!(
        Supervisor.child_spec(
          {Pool, name: pool_b, host: "127.0.0.1", port: port, pool_size: 2, backoff_initial: 10},
          id: pool_b
        )
      )

      tasks =
        for pool <- [pool_a, pool_a, pool_a, pool_b, pool_b, pool_b] do
          Task.async(fn -> services(pool) end)
        end

      assert Enum.all?(Task.await_many(tasks, 5_000), &(&1 == {:ok, ["a", "b"]}))
      assert Agent.get(tracker, & &1.max) == 1
    end

    test "runs jobs in parallel across connections to distinct soffice instances" do
      {:ok, tracker} = Agent.start_link(fn -> %{active: 0, max: 0} end)

      on_call = fn
        :start, _oid ->
          Agent.update(tracker, fn %{active: a, max: m} ->
            %{active: a + 1, max: max(m, a + 1)}
          end)

        :stop, _oid ->
          Agent.update(tracker, &%{&1 | active: &1.active - 1})
      end

      port1 = FakeSoffice.start([{:after, 120}], on_call: on_call)
      port2 = FakeSoffice.start([{:after, 120}], on_call: on_call)
      pool1 = :"par_1_#{System.unique_integer([:positive])}"
      pool2 = :"par_2_#{System.unique_integer([:positive])}"

      start_supervised!(
        Supervisor.child_spec(
          {Pool, name: pool1, host: "127.0.0.1", port: port1, pool_size: 1, backoff_initial: 10},
          id: pool1
        )
      )

      start_supervised!(
        Supervisor.child_spec(
          {Pool, name: pool2, host: "127.0.0.1", port: port2, pool_size: 1, backoff_initial: 10},
          id: pool2
        )
      )

      tasks = [Task.async(fn -> services(pool1) end), Task.async(fn -> services(pool2) end)]
      assert Task.await_many(tasks, 5_000) == [{:ok, ["a", "b"]}, {:ok, ["a", "b"]}]
      assert Agent.get(tracker, & &1.max) == 2
    end
  end

  describe "address/2" do
    setup do
      lookup = :inet_db.res_option(:lookup)
      :inet_db.set_lookup([:file | lookup])
      name = "soffice-#{System.unique_integer([:positive])}"
      :inet_db.add_host({127, 0, 0, 2}, [String.to_charlist(name)])
      :inet_db.add_host({127, 0, 0, 1}, [String.to_charlist(name)])

      on_exit(fn ->
        :inet_db.del_host({127, 0, 0, 1})
        :inet_db.del_host({127, 0, 0, 2})
        :inet_db.set_lookup(lookup)
      end)

      %{name: name}
    end

    test "gives each connection of a pool the next address in turn", %{name: name} do
      assert Connection.address(name, 0) == "127.0.0.1"
      assert Connection.address(name, 1) == "127.0.0.2"
      assert Connection.address(name, 2) == "127.0.0.1"
    end

    test "passes an address literal through" do
      assert Connection.address("127.0.0.1", 3) == "127.0.0.1"
    end

    test "falls back to the name itself when resolution fails" do
      assert Connection.address("urp-pool.invalid", 0) == "urp-pool.invalid"
    end
  end
end

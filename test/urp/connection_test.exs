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
      notify = Keyword.get(opts, :notify)
      spawn_link(fn -> accept(listen, script, oid, notify) end)
      port
    end

    defp accept(listen, script, oid, notify) do
      {:ok, sock} = :gen_tcp.accept(listen)

      spawn_link(fn ->
        try do
          handshake(sock)
          serve(sock, script, oid, notify)
        rescue
          URP.SocketError -> :ok
        end
      end)

      accept(listen, script, oid, notify)
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
    defp serve(sock, script, oid, notify) do
      case P.recv_frame(sock, 5_000) do
        <<_flags, 0, _::binary>> ->
          reply(sock, P.encode(:any, {{:interface, @interface}, oid}))

        <<_flags, function, _::binary>> when function in [3, 4] ->
          reply(sock, P.encode({:interface, @interface}, oid))

        <<_flags, 5, _::binary>> ->
          if notify, do: send(notify, {:call, :start, oid})
          services = P.encode({:sequence, :string}, ["a", "b"])
          step = Agent.get_and_update(script, &List.pop_at(&1, 0))
          if match?({:after, _}, step), do: Process.sleep(elem(step, 1))
          if step == :say_nothing, do: Process.sleep(2_000)
          if notify, do: send(notify, {:call, :stop, oid})

          if step in [nil, :answer_then_hang_up] or match?({:after, _}, step),
            do: reply(sock, services)

          if step in [:hang_up, :answer_then_hang_up], do: :gen_tcp.close(sock)
      end

      serve(sock, script, oid, notify)
    end

    defp reply(sock, body), do: P.send_frame(sock, [<<0x80>>, body])

    def peak_concurrency(count) do
      for _ <- 1..(count * 2), reduce: {%{}, %{}, 0, 0} do
        {cur, peaks, total, total_peak} ->
          receive do
            {:call, :start, oid} ->
              n = Map.get(cur, oid, 0) + 1
              t = total + 1

              {Map.put(cur, oid, n), Map.update(peaks, oid, n, &max(&1, n)), t,
               max(total_peak, t)}

            {:call, :stop, oid} ->
              {Map.update!(cur, oid, &(&1 - 1)), peaks, total - 1, total_peak}
          after
            5_000 -> raise "timed out waiting for FakeSoffice call events"
          end
      end
      |> then(fn {_cur, peaks, _total, total_peak} -> {peaks, total_peak} end)
    end
  end

  defp start_pool(script, opts \\ []) do
    name = :"connection_test_#{System.unique_integer([:positive])}"
    {port, opts} = Keyword.pop_lazy(opts, :port, fn -> FakeSoffice.start(script) end)

    start_supervised!(
      Supervisor.child_spec(
        {Pool, [name: name, host: "127.0.0.1", port: port, backoff_initial: 10] ++ opts},
        id: name
      )
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

      stop_supervised!(pool)

      assert Task.await(job) == {:ok, ["a", "b"]}
    end

    test "serializes jobs per soffice across connections and pools, while running distinct ones in parallel" do
      port1 = FakeSoffice.start(List.duplicate({:after, 60}, 6), oid: "s1", notify: self())
      port2 = FakeSoffice.start(List.duplicate({:after, 60}, 2), oid: "s2", notify: self())

      pool_a = start_pool([], port: port1, pool_size: 3)
      pool_b = start_pool([], port: port1, pool_size: 2)
      pool_c = start_pool([], port: port2, pool_size: 1)

      tasks =
        for pool <- [pool_a, pool_a, pool_b, pool_b, pool_c, pool_c],
            do: Task.async(fn -> services(pool) end)

      assert Enum.all?(Task.await_many(tasks, 5_000), &(&1 == {:ok, ["a", "b"]}))
      assert {%{"s1" => 1, "s2" => 1}, 2} = FakeSoffice.peak_concurrency(6)
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

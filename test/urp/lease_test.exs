defmodule URP.LeaseTest do
  use ExUnit.Case, async: false

  alias URP.Lease

  describe "single-node lease" do
    test "grants a soffice to one connection at a time and wakes subscribers on release" do
      sid = "soffice-#{System.unique_integer([:positive])}"
      Lease.subscribe()

      c1 = spawn_link(fn -> Process.sleep(:infinity) end)
      c2 = spawn_link(fn -> Process.sleep(:infinity) end)

      assert :ok = Lease.acquire(sid, c1)
      assert {:busy, ^c1} = Lease.acquire(sid, c2)

      # Releasing as a non-holder does nothing.
      assert :ok = Lease.release(sid, c2)
      assert {:busy, ^c1} = Lease.acquire(sid, c2)

      # Releasing as the holder frees the soffice and wakes subscribers.
      assert :ok = Lease.release(sid, c1)
      assert_receive {:lease_released, ^sid}
      assert :ok = Lease.acquire(sid, c2)
      assert :ok = Lease.release(sid, c2)
    end

    test "releases a soffice automatically when its holding connection crashes" do
      sid = "soffice-#{System.unique_integer([:positive])}"
      c1 = spawn(fn -> Process.sleep(:infinity) end)
      c2 = spawn_link(fn -> Process.sleep(:infinity) end)

      assert :ok = Lease.acquire(sid, c1)
      assert {:busy, ^c1} = Lease.acquire(sid, c2)

      ref = Process.monitor(c1)
      Process.exit(c1, :kill)
      assert_receive {:DOWN, ^ref, :process, ^c1, :killed}

      # :global cleans up on :DOWN; retry briefly until global processes the exit.
      assert eventually(fn -> Lease.acquire(sid, c2) == :ok end)
      assert :ok = Lease.release(sid, c2)
    end
  end

  describe "multi-node cluster" do
    @describetag :cluster

    setup do
      unless Node.alive?() do
        System.cmd("epmd", ["-daemon"])

        case :net_kernel.start([
               :"urp_test_#{System.unique_integer([:positive])}",
               :shortnames
             ]) do
          {:ok, _} -> :ok
          {:error, {:already_started, _}} -> :ok
          {:error, reason} -> flunk("could not start distributed node: #{inspect(reason)}")
        end
      end

      :ok
    end

    defp start_peer(label, opts \\ []) do
      code_paths = Enum.flat_map(:code.get_path(), fn path -> [~c"-pa", path] end)
      isolated = Keyword.get(opts, :isolated, false)

      peer_opts = %{
        name: :"urp_#{label}_#{System.unique_integer([:positive])}",
        args: code_paths ++ [~c"-setcookie", Atom.to_charlist(Node.get_cookie())]
      }

      peer_opts =
        if isolated, do: Map.put(peer_opts, :connection, :standard_io), else: peer_opts

      {:ok, pid, node_name} = :peer.start(peer_opts)

      {:ok, _} =
        if isolated do
          :peer.call(pid, Application, :ensure_all_started, [:urp])
        else
          :erpc.call(node_name, Application, :ensure_all_started, [:urp])
        end

      on_exit(fn ->
        try do
          if Process.alive?(pid), do: :peer.stop(pid)
        catch
          :exit, _ -> :ok
        end
      end)

      {pid, node_name}
    end

    test "serializes jobs across nodes sharing one soffice and runs distinct soffices in parallel" do
      {_p1, n1} = start_peer(:a)
      {_p2, n2} = start_peer(:b)

      assert :erpc.call(n1, Node, :connect, [n2]) == true

      {:ok, tracker} =
        Agent.start_link(fn -> %{by_oid: %{}, max_by_oid: %{}, total_max: 0, total: 0} end)

      on_call = fn
        :start, oid ->
          Agent.update(tracker, fn s ->
            cur = Map.get(s.by_oid, oid, 0) + 1
            total = s.total + 1

            %{
              by_oid: Map.put(s.by_oid, oid, cur),
              max_by_oid: Map.update(s.max_by_oid, oid, cur, &max(&1, cur)),
              total: total,
              total_max: max(s.total_max, total)
            }
          end)

        :stop, oid ->
          Agent.update(tracker, fn s ->
            %{
              s
              | by_oid: Map.update!(s.by_oid, oid, &(&1 - 1)),
                total: s.total - 1
            }
          end)
      end

      port1 =
        URP.ConnectionTest.FakeSoffice.start(
          List.duplicate({:after, 80}, 12),
          oid: "cluster-s1",
          on_call: on_call
        )

      port2 =
        URP.ConnectionTest.FakeSoffice.start(
          List.duplicate({:after, 80}, 12),
          oid: "cluster-s2",
          on_call: on_call
        )

      for n <- [n1, n2] do
        :ok =
          :erpc.call(n, Application, :put_env, [
            :urp,
            :pools,
            [
              p1: [host: "127.0.0.1", port: port1, pool_size: 2, backoff_initial: 10],
              p2: [host: "127.0.0.1", port: port2, pool_size: 1, backoff_initial: 10]
            ]
          ])
      end

      tasks = [
        Task.async(fn -> :erpc.call(n1, URP, :services, [[pool: :p1]]) end),
        Task.async(fn -> :erpc.call(n2, URP, :services, [[pool: :p1]]) end),
        Task.async(fn -> :erpc.call(n1, URP, :services, [[pool: :p1]]) end),
        Task.async(fn -> :erpc.call(n2, URP, :services, [[pool: :p2]]) end),
        Task.async(fn -> :erpc.call(n1, URP, :services, [[pool: :p2]]) end)
      ]

      results = Task.await_many(tasks, 10_000)
      assert Enum.all?(results, &(&1 == {:ok, ["a", "b"]}))

      stats = Agent.get(tracker, & &1)
      assert stats.max_by_oid["cluster-s1"] == 1
      assert stats.max_by_oid["cluster-s2"] == 1
      assert stats.total_max == 2
    end

    test "releases a soffice immediately when the holding node goes down" do
      {p1, n1} = start_peer(:down_a)
      {_p2, n2} = start_peer(:down_b)

      assert :erpc.call(n1, Node, :connect, [n2]) == true
      :ok = :erpc.call(n1, :global, :sync, [])
      :ok = :erpc.call(n2, :global, :sync, [])

      sid = "soffice-down-#{System.unique_integer([:positive])}"
      conn1 = :erpc.call(n1, :erlang, :spawn, [Process, :sleep, [:infinity]])
      conn2 = :erpc.call(n2, :erlang, :spawn, [Process, :sleep, [:infinity]])

      assert :ok = :erpc.call(n1, Lease, :acquire, [sid, conn1])
      assert {:busy, ^conn1} = :erpc.call(n2, Lease, :acquire, [sid, conn2])

      # Stop the node holding the lease; n2 should be able to acquire immediately.
      :peer.stop(p1)
      assert eventually(fn -> :erpc.call(n2, Lease, :acquire, [sid, conn2]) == :ok end)
      assert :ok = :erpc.call(n2, Lease, :release, [sid, conn2])
    end

    test "syncs an in-flight lease when a new node joins the cluster" do
      {p1, n1} = start_peer(:join_a, isolated: true)
      {p2, n2} = start_peer(:join_b, isolated: true)

      refute n2 in :peer.call(p1, Node, :list, [])

      sid = "soffice-join-#{System.unique_integer([:positive])}"
      conn1 = :peer.call(p1, :erlang, :spawn, [Process, :sleep, [:infinity]])
      conn2 = :peer.call(p2, :erlang, :spawn, [Process, :sleep, [:infinity]])

      # n1 already holds the lease before n2 connects (as when a pod joins via DNSCluster).
      assert :ok = :peer.call(p1, Lease, :acquire, [sid, conn1])

      assert :peer.call(p2, Node, :connect, [n1]) == true
      :ok = :peer.call(p2, :global, :sync, [])

      assert {:busy, ^conn1} = :peer.call(p2, Lease, :acquire, [sid, conn2])

      assert :ok = :peer.call(p1, Lease, :release, [sid, conn1])
      assert :ok = :peer.call(p2, Lease, :acquire, [sid, conn2])
      assert :ok = :peer.call(p2, Lease, :release, [sid, conn2])
    end
  end

  defp eventually(fun, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_eventually(fun, deadline)
  end

  defp do_eventually(fun, deadline) do
    if fun.() do
      true
    else
      if System.monotonic_time(:millisecond) > deadline do
        false
      else
        Process.sleep(10)
        do_eventually(fun, deadline)
      end
    end
  end
end

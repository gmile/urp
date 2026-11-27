defmodule URP.LeaseTest do
  use ExUnit.Case, async: false

  alias URP.ConnectionTest.FakeSoffice
  alias URP.Lease

  test "leases a soffice to one connection at a time and releases on owner exit" do
    sid = "soffice-#{System.unique_integer([:positive])}"
    Lease.subscribe()

    c1 = spawn(fn -> Process.sleep(:infinity) end)
    c2 = spawn_link(fn -> Process.sleep(:infinity) end)

    assert :ok = Lease.acquire(sid, c1)
    assert {:busy, ^c1} = Lease.acquire(sid, c2)

    # Non-holder release is ignored; holder release wakes subscribers.
    assert :ok = Lease.release(sid, c2)
    assert {:busy, ^c1} = Lease.acquire(sid, c2)
    assert :ok = Lease.release(sid, c1)
    assert_receive :lease_released

    # Crashing holder releases automatically.
    assert :ok = Lease.acquire(sid, c1)
    Process.exit(c1, :kill)
    assert eventually(fn -> Lease.acquire(sid, c2) == :ok end)
    assert :ok = Lease.release(sid, c2)
  end

  describe "cluster" do
    setup do
      unless Node.alive?() do
        System.cmd("epmd", ["-daemon"])
        :net_kernel.start([:"urp_test_#{System.unique_integer([:positive])}", :shortnames])
      end

      :ok
    end

    defp start_peer(label, opts \\ []) do
      args =
        Enum.flat_map(:code.get_path(), &[~c"-pa", &1]) ++
          [~c"-setcookie", Atom.to_charlist(Node.get_cookie())]

      peer = %{name: :"urp_#{label}_#{System.unique_integer([:positive])}", args: args}
      peer = if opts[:isolated], do: Map.put(peer, :connection, :standard_io), else: peer
      {:ok, pid, name} = :peer.start(peer)

      {:ok, _} =
        if opts[:isolated],
          do: :peer.call(pid, Application, :ensure_all_started, [:urp]),
          else: :erpc.call(name, Application, :ensure_all_started, [:urp])

      on_exit(fn -> try do: :peer.stop(pid), catch: (:exit, _ -> :ok) end)
      {pid, name}
    end

    test "serializes a shared soffice across nodes while running distinct ones in parallel" do
      {_p1, n1} = start_peer(:a)
      {_p2, n2} = start_peer(:b)
      assert :erpc.call(n1, Node, :connect, [n2]) == true

      p1 = FakeSoffice.start(List.duplicate({:after, 60}, 6), oid: "c1", notify: self())
      p2 = FakeSoffice.start(List.duplicate({:after, 60}, 4), oid: "c2", notify: self())

      for n <- [n1, n2] do
        :erpc.call(n, Application, :put_env, [
          :urp,
          :pools,
          [
            p1: [host: "127.0.0.1", port: p1, pool_size: 2, backoff_initial: 10],
            p2: [host: "127.0.0.1", port: p2, pool_size: 1, backoff_initial: 10]
          ]
        ])
      end

      tasks =
        for {n, pool} <- [{n1, :p1}, {n2, :p1}, {n1, :p1}, {n2, :p2}, {n1, :p2}],
            do: Task.async(fn -> :erpc.call(n, URP, :services, [[pool: pool]]) end)

      assert Enum.all?(Task.await_many(tasks, 10_000), &(&1 == {:ok, ["a", "b"]}))
      assert {%{"c1" => 1, "c2" => 1}, 2} = FakeSoffice.peak_concurrency(5)
    end

    test "releases on node down and syncs in-flight leases when a new node joins" do
      {p1, n1} = start_peer(:join_a, isolated: true)
      {p2, _n2} = start_peer(:join_b, isolated: true)
      sid = "soffice-cluster-#{System.unique_integer([:positive])}"

      c1 = :peer.call(p1, :erlang, :spawn, [Process, :sleep, [:infinity]])
      c2 = :peer.call(p2, :erlang, :spawn, [Process, :sleep, [:infinity]])

      # n1 leases before n2 joins (e.g. via DNSCluster); n2 sees it immediately after connect.
      assert :ok = :peer.call(p1, Lease, :acquire, [sid, c1])
      assert :peer.call(p2, Node, :connect, [n1]) == true
      assert {:busy, ^c1} = :peer.call(p2, Lease, :acquire, [sid, c2])

      # Stopping n1 releases the lease so n2 can acquire it.
      :peer.stop(p1)
      assert eventually(fn -> :peer.call(p2, Lease, :acquire, [sid, c2]) == :ok end)
      assert :ok = :peer.call(p2, Lease, :release, [sid, c2])
    end
  end

  defp eventually(fun, deadline \\ System.monotonic_time(:millisecond) + 2_000) do
    cond do
      fun.() -> true
      System.monotonic_time(:millisecond) > deadline -> false
      true -> Process.sleep(10) && eventually(fun, deadline)
    end
  end
end

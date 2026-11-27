defmodule URP.QueueTest do
  use ExUnit.Case, async: true

  alias URP.Queue

  setup do
    name = :"queue_test_#{System.unique_integer([:positive])}"
    start_supervised!({Queue, name})
    %{queue: name}
  end

  defp job(deadline \\ :infinity), do: %{fun: &Function.identity/1, deadline: deadline, opts: []}

  # A caller that waits for its job in a process of its own, as callers do.
  defp caller(queue, job) do
    test = self()
    spawn_link(fn -> send(test, {:answer, GenServer.call(queue, {:run, job}, :infinity)}) end)
  end

  test "a job goes to a connection that is ready, which answers its caller", %{queue: queue} do
    Queue.ready(queue)
    caller(queue, job())

    assert_receive {:job, from, %{deadline: :infinity}}
    GenServer.reply(from, :done)
    assert_receive {:answer, :done}
  end

  test "a job waits until a connection is ready", %{queue: queue} do
    caller(queue, job())
    refute_receive {:job, _from, _job}, 50

    Queue.ready(queue)
    assert_receive {:job, _from, _job}
  end

  test "jobs are handed out in the order they came", %{queue: queue} do
    for n <- 1..3 do
      caller(queue, Map.put(job(), :n, n))
      :sys.get_state(queue)
    end

    for n <- 1..3 do
      Queue.ready(queue)
      assert_receive {:job, _from, %{n: ^n}}
    end
  end

  test "a connection gets one job each time it says it is ready", %{queue: queue} do
    Queue.ready(queue)
    caller(queue, job())
    caller(queue, job())

    assert_receive {:job, _from, _job}
    refute_receive {:job, _from, _job}, 50
  end

  test "a job whose caller has stopped waiting is never handed out", %{queue: queue} do
    caller(queue, Map.put(job(Queue.deadline(0)), :n, :expired))
    caller(queue, Map.put(job(), :n, :live))
    :sys.get_state(queue)
    Process.sleep(2)

    Queue.ready(queue)
    assert_receive {:job, _from, %{n: :live}}
  end

  test "a connection that has gone is not handed a job", %{queue: queue} do
    test = self()

    {gone, ref} =
      spawn_monitor(fn ->
        Queue.ready(queue)
        :sys.get_state(queue)
        send(test, :registered)
      end)

    assert_receive :registered
    assert_receive {:DOWN, ^ref, :process, ^gone, :normal}
    :sys.get_state(queue)

    Queue.ready(queue)
    caller(queue, job())
    assert_receive {:job, _from, _job}
  end
end

defmodule URP.Queue do
  @moduledoc false

  # Jobs waiting for a connection, and connections waiting for a job. A job is
  # handed to the connection that has waited longest whose `soffice` is free
  # across the cluster, which answers its caller directly. A job whose caller
  # has stopped waiting is dropped unrun.

  use GenServer

  alias URP.Lease

  @type job :: %{fun: (URP.Connection.t() -> term()), deadline: timeout(), timeout: timeout()}

  @spec start_link(GenServer.name()) :: GenServer.on_start()
  def start_link(name), do: GenServer.start_link(__MODULE__, nil, name: name)

  @doc "Tell `queue` that the calling connection can take a job on `soffice_id`."
  @spec ready(GenServer.server(), Lease.soffice_id()) :: :ok
  def ready(queue, soffice_id \\ make_ref()),
    do: GenServer.cast(queue, {:ready, soffice_id, self()})

  @doc "Tell `queue` that the calling connection dropped and is no longer busy."
  @spec release(GenServer.server()) :: :ok
  def release(queue), do: GenServer.cast(queue, {:release, self()})

  @doc "Release the calling connection and put an unstarted job back at the front of `queue`."
  @spec requeue(GenServer.server(), GenServer.from(), job()) :: :ok
  def requeue(queue, from, job), do: GenServer.cast(queue, {:requeue, self(), from, job})

  @doc "The moment, on the monotonic clock, at which a wait of `timeout` ends."
  @spec deadline(timeout()) :: timeout()
  def deadline(:infinity), do: :infinity
  def deadline(timeout), do: System.monotonic_time(:millisecond) + timeout

  @spec expired?(timeout()) :: boolean()
  def expired?(:infinity), do: false
  def expired?(deadline), do: System.monotonic_time(:millisecond) > deadline

  @impl GenServer
  def init(nil) do
    Lease.subscribe()
    {:ok, %{jobs: :queue.new(), ready: [], held: %{}, monitors: %{}, watching: %{}}}
  end

  @impl GenServer
  def handle_call({:run, job}, from, state) do
    {:noreply, dispatch(%{state | jobs: :queue.in({from, job}, state.jobs)})}
  end

  @impl GenServer
  def handle_cast({:ready, soffice_id, pid}, state) do
    state = release_held(state, pid)
    monitors = Map.put_new_lazy(state.monitors, pid, fn -> Process.monitor(pid) end)
    ready = Enum.reject(state.ready, &match?({^pid, _}, &1)) ++ [{pid, soffice_id}]
    {:noreply, dispatch(%{state | ready: ready, monitors: monitors})}
  end

  def handle_cast({:release, pid}, state) do
    {:noreply, state |> release_held(pid) |> dispatch()}
  end

  def handle_cast({:requeue, pid, from, job}, state) do
    state = release_held(state, pid)
    {:noreply, dispatch(%{state | jobs: :queue.in_r({from, job}, state.jobs)})}
  end

  @impl GenServer
  def handle_info(:lease_released, state), do: {:noreply, dispatch(state)}

  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    cond do
      state.monitors[pid] == ref ->
        ready = Enum.reject(state.ready, &match?({^pid, _}, &1))
        held = Map.delete(state.held, pid)
        {:noreply, %{state | ready: ready, held: held, monitors: Map.delete(state.monitors, pid)}}

      state.watching[pid] == ref ->
        {:noreply, dispatch(%{state | watching: Map.delete(state.watching, pid)})}

      true ->
        {:noreply, state}
    end
  end

  defp dispatch(state) do
    case :queue.out(state.jobs) do
      {:empty, _jobs} ->
        for {_pid, ref} <- state.watching, do: Process.demonitor(ref, [:flush])
        %{state | watching: %{}}

      {{:value, {from, job}}, jobs} ->
        if expired?(job.deadline) do
          dispatch(%{state | jobs: jobs})
        else
          case take_ready(state.ready, [], state.watching) do
            {:ok, pid, sid, ready, watching} ->
              send(pid, {:job, from, job})
              held = Map.put(state.held, pid, sid)
              dispatch(%{state | jobs: jobs, ready: ready, held: held, watching: watching})

            {:none, ready, watching} ->
              %{state | ready: ready, watching: watching}
          end
        end
    end
  end

  defp take_ready([], seen, watching), do: {:none, Enum.reverse(seen), watching}

  defp take_ready([{pid, sid} = entry | rest], seen, watching) do
    cond do
      not Process.alive?(pid) ->
        take_ready(rest, seen, watching)

      true ->
        case Lease.acquire(sid, pid) do
          :ok ->
            {:ok, pid, sid, Enum.reverse(seen, rest), watching}

          {:busy, holder} ->
            watching =
              if is_pid(holder),
                do: Map.put_new_lazy(watching, holder, fn -> Process.monitor(holder) end),
                else: watching

            take_ready(rest, [entry | seen], watching)
        end
    end
  end

  defp release_held(state, pid) do
    case Map.pop(state.held, pid) do
      {nil, _held} ->
        state

      {sid, held} ->
        Lease.release(sid, pid)
        %{state | held: held}
    end
  end
end

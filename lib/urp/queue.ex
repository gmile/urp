defmodule URP.Queue do
  @moduledoc false

  # Jobs waiting for a connection, and connections waiting for a job. A job is
  # handed to the connection that has waited longest whose `soffice` is not busy
  # anywhere in the cluster, which answers its caller directly. A job whose
  # caller has stopped waiting is dropped unrun.

  use GenServer

  alias URP.Lease

  @type job :: %{fun: (URP.Connection.t() -> term()), deadline: timeout(), timeout: timeout()}

  @spec start_link(GenServer.name()) :: GenServer.on_start()
  def start_link(name), do: GenServer.start_link(__MODULE__, nil, name: name)

  @doc "Tell `queue` that the calling connection can take a job on `soffice_id`."
  @spec ready(GenServer.server(), Lease.soffice_id()) :: :ok
  def ready(queue, soffice_id \\ make_ref()) do
    GenServer.cast(queue, {:ready, soffice_id, self()})
  end

  @doc "Put an unstarted job back at the front of `queue`."
  @spec requeue(GenServer.server(), GenServer.from(), job()) :: :ok
  def requeue(queue, from, job) do
    GenServer.cast(queue, {:requeue, from, job})
  end

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

  def handle_cast({:requeue, from, job}, state) do
    {:noreply, dispatch(%{state | jobs: :queue.in_r({from, job}, state.jobs)})}
  end

  @impl GenServer
  def handle_info({:lease_released, _soffice_id}, state) do
    {:noreply, dispatch(state)}
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    state =
      if Map.get(state.monitors, pid) == ref do
        %{
          state
          | ready: Enum.reject(state.ready, &match?({^pid, _}, &1)),
            held: Map.delete(state.held, pid),
            monitors: Map.delete(state.monitors, pid)
        }
      else
        state
      end

    if Map.get(state.watching, pid) == ref do
      {:noreply, dispatch(%{state | watching: Map.delete(state.watching, pid)})}
    else
      {:noreply, state}
    end
  end

  defp dispatch(state) do
    case :queue.out(state.jobs) do
      {:empty, _jobs} ->
        clear_watching(state)

      {{:value, {from, job}}, jobs} ->
        if expired?(job.deadline) do
          dispatch(%{state | jobs: jobs})
        else
          case acquire_ready(state.ready, [], state.watching) do
            {:ok, pid, soffice_id, ready, watching} ->
              send(pid, {:job, from, job})

              dispatch(%{
                state
                | jobs: jobs,
                  ready: ready,
                  held: Map.put(state.held, pid, soffice_id),
                  watching: watching
              })

            {:none, ready, watching} ->
              %{state | ready: ready, watching: watching}
          end
        end
    end
  end

  defp acquire_ready([], seen, watching), do: {:none, Enum.reverse(seen), watching}

  defp acquire_ready([{pid, soffice_id} = entry | rest], seen, watching) do
    if not Process.alive?(pid) do
      acquire_ready(rest, seen, watching)
    else
      case try_acquire(soffice_id, pid, 3) do
        :ok ->
          {:ok, pid, soffice_id, Enum.reverse(seen, rest), watching}

        {:busy, holder} ->
          watching = Map.put_new_lazy(watching, holder, fn -> Process.monitor(holder) end)
          acquire_ready(rest, [entry | seen], watching)

        :retry ->
          acquire_ready(rest, [entry | seen], watching)
      end
    end
  end

  defp release_held(state, pid) do
    case Map.pop(state.held, pid) do
      {nil, _held} ->
        state

      {soffice_id, held} ->
        Lease.release(soffice_id, pid)
        %{state | held: held}
    end
  end

  defp try_acquire(_soffice_id, _pid, 0), do: :retry

  defp try_acquire(soffice_id, pid, attempts) do
    case Lease.acquire(soffice_id, pid) do
      :retry -> try_acquire(soffice_id, pid, attempts - 1)
      other -> other
    end
  end

  defp clear_watching(%{watching: watching} = state) when map_size(watching) == 0, do: state

  defp clear_watching(state) do
    for {_pid, ref} <- state.watching, do: Process.demonitor(ref, [:flush])
    %{state | watching: %{}}
  end
end

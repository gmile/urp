defmodule URP.Queue do
  @moduledoc false

  # Jobs waiting for a connection, and connections waiting for a job. A job is
  # handed to the connection that has waited longest, which answers its caller
  # directly. A job whose caller has stopped waiting is dropped unrun.

  use GenServer

  @type job :: %{fun: (URP.Connection.t() -> term()), deadline: timeout(), timeout: timeout()}

  @spec start_link(GenServer.name()) :: GenServer.on_start()
  def start_link(name), do: GenServer.start_link(__MODULE__, nil, name: name)

  @doc "Tell `queue` that the calling connection can take a job."
  @spec ready(GenServer.server()) :: :ok
  def ready(queue), do: GenServer.cast(queue, {:ready, self()})

  @doc "The moment, on the monotonic clock, at which a wait of `timeout` ends."
  @spec deadline(timeout()) :: timeout()
  def deadline(:infinity), do: :infinity
  def deadline(timeout), do: System.monotonic_time(:millisecond) + timeout

  @spec expired?(timeout()) :: boolean()
  def expired?(deadline), do: System.monotonic_time(:millisecond) > deadline

  @impl GenServer
  def init(nil), do: {:ok, %{jobs: :queue.new(), ready: :queue.new(), monitors: %{}}}

  @impl GenServer
  def handle_call({:run, job}, from, state) do
    {:noreply, dispatch(%{state | jobs: :queue.in({from, job}, state.jobs)})}
  end

  @impl GenServer
  def handle_cast({:ready, pid}, state) do
    monitors = Map.put_new_lazy(state.monitors, pid, fn -> Process.monitor(pid) end)
    {:noreply, dispatch(%{state | ready: :queue.in(pid, state.ready), monitors: monitors})}
  end

  @impl GenServer
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    ready = :queue.delete(pid, state.ready)
    {:noreply, %{state | ready: ready, monitors: Map.delete(state.monitors, pid)}}
  end

  defp dispatch(state) do
    case :queue.out(state.jobs) do
      {:empty, _jobs} ->
        state

      {{:value, {from, job}}, jobs} ->
        cond do
          expired?(job.deadline) ->
            dispatch(%{state | jobs: jobs})

          :queue.is_empty(state.ready) ->
            state

          true ->
            {{:value, pid}, ready} = :queue.out(state.ready)
            send(pid, {:job, from, job})
            dispatch(%{state | jobs: jobs, ready: ready})
        end
    end
  end
end

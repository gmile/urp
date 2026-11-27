defmodule URP.Pool do
  @moduledoc false

  # A pool is a queue of jobs and the connections that take them, under one
  # supervisor. Callers put a job in the queue; a connection asks for one when
  # it has nothing to do, so a connection that is busy, reconnecting or stuck
  # never holds one up.

  use Supervisor

  alias URP.{Connection, Queue}

  @default_timeout 120_000

  @doc false
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts)
  end

  @impl Supervisor
  def init(opts) do
    {name, opts} = Keyword.pop!(opts, :name)
    {size, opts} = Keyword.pop(opts, :pool_size, 1)

    connections =
      for index <- 0..(size - 1)//1 do
        Supervisor.child_spec({Connection, [queue: name, index: index] ++ opts}, id: index)
      end

    # If the queue goes, the connections that were told about it go too.
    Supervisor.init([{Queue, name} | connections], strategy: :rest_for_one)
  end

  @doc """
  Run `fun` on a connection from `pool` and wait up to `:timeout` for it.

  `operation` names the work for telemetry.
  """
  @spec run(GenServer.server(), atom(), keyword(), (Connection.t() -> result)) ::
          {:ok, result} | {:error, URP.error()}
        when result: term()
  def run(pool, operation, opts, fun) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    meta = %{operation: operation, pool: pool}

    :telemetry.span([:urp, :call], meta, fn ->
      requested = System.monotonic_time()
      job = %{fun: fun, deadline: Queue.deadline(timeout), timeout: timeout}

      {result, measurements} =
        try do
          {result, started} = GenServer.call(pool, {:run, job}, timeout)
          finished = System.monotonic_time()
          {result, %{queue_time: started - requested, service_time: finished - started}}
        catch
          :exit, {:timeout, _call} -> {{:error, :timeout}, %{}}
          :exit, _reason -> {{:error, :unavailable}, %{}}
        end

      {result, measurements, Map.put(meta, :result, elem(result, 0))}
    end)
  end
end

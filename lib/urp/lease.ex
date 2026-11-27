defmodule URP.Lease do
  @moduledoc false

  # Cluster-wide mutual exclusion per `soffice` process, built on OTP's
  # `:global` and `:pg`.
  #
  # Each `soffice` process is identified by the UNO OID of its
  # `StarOffice.ComponentContext`, which embeds a process-wide identifier: two
  # connections to the same `soffice` share it (even through a load balancer),
  # while separate instances and restarts differ.
  #
  # Holding a lease registers `{URP.Lease, soffice_id}` in `:global` under the
  # connection's pid, so OTP releases it automatically if the connection or its
  # node goes down. Waiting queues join a `:pg` group and are woken on release.

  @type soffice_id :: String.t() | reference()

  @scope __MODULE__
  @group :queues

  @doc false
  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(_arg) do
    %{id: @scope, start: {:pg, :start_link, [@scope]}}
  end

  @doc "Subscribe `queue` to lease release notifications across the cluster."
  @spec subscribe(pid()) :: :ok
  def subscribe(queue \\ self()) do
    :pg.join(@scope, @group, queue)
  end

  @doc """
  Try to acquire the lease for `soffice_id` on behalf of `conn`.

  Returns `:ok`, `{:busy, holder_pid}` if another connection holds it, or
  `:retry` if the holder released it concurrently.
  """
  @spec acquire(soffice_id(), pid()) :: :ok | {:busy, pid()} | :retry
  def acquire(soffice_id, conn) do
    if Node.list() != [], do: :global.sync()
    name = {__MODULE__, soffice_id}

    case :global.register_name(name, conn, &__MODULE__.keep/3) do
      :yes ->
        :ok

      :no ->
        case :global.whereis_name(name) do
          pid when is_pid(pid) -> {:busy, pid}
          :undefined -> :retry
        end
    end
  end

  @doc "Release `soffice_id` if `conn` holds it, and wake waiting queues."
  @spec release(soffice_id(), pid()) :: :ok
  def release(soffice_id, conn) do
    name = {__MODULE__, soffice_id}

    if :global.whereis_name(name) == conn do
      :global.unregister_name(name)
      broadcast(soffice_id)
    end

    :ok
  end

  # If two nodes held the same soffice across a partition, keep one
  # deterministically without killing either connection process.
  @doc false
  @spec keep(term(), pid(), pid()) :: pid()
  def keep(_name, pid1, pid2) do
    if node(pid1) <= node(pid2), do: pid1, else: pid2
  end

  defp broadcast(soffice_id) do
    local = :pg.get_local_members(@scope, @group)
    remote = :pg.get_members(@scope, @group) -- local

    for queue <- remote, do: send(queue, {:lease_released, soffice_id})
    for queue <- local, do: send(queue, {:lease_released, soffice_id})
    :ok
  end
end

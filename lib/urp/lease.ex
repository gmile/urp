defmodule URP.Lease do
  @moduledoc false

  # Cluster-wide one-at-a-time lease per `soffice` process, built on OTP's
  # `:global` and `:pg`.
  #
  # Each `soffice` is identified by the UNO OID of its
  # `StarOffice.ComponentContext`, which is shared by every connection to that
  # process (even behind a load balancer) and differs across instances and
  # restarts. Holding a lease registers `{URP.Lease, soffice_id}` under the
  # connection's pid, so OTP releases it automatically if the connection or its
  # node goes down. Waiting queues join `:pg` and are woken on release.

  @type soffice_id :: String.t() | reference()

  @doc false
  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(_arg), do: %{id: __MODULE__, start: {:pg, :start_link, [__MODULE__]}}

  @doc "Subscribe the calling queue to lease release notices."
  @spec subscribe() :: :ok
  def subscribe, do: :pg.join(__MODULE__, :queues, self())

  @doc "Try to lease `soffice_id` for `conn`. Returns `:ok` or `{:busy, holder}`."
  @spec acquire(soffice_id(), pid()) :: :ok | {:busy, pid() | nil}
  def acquire(soffice_id, conn) do
    if Node.list() != [], do: :global.sync()
    do_acquire({__MODULE__, soffice_id}, conn, 3)
  end

  defp do_acquire(_name, _conn, 0), do: {:busy, nil}

  defp do_acquire(name, conn, attempts) do
    case :global.register_name(name, conn, &__MODULE__.keep/3) do
      :yes ->
        :ok

      :no ->
        case :global.whereis_name(name) do
          pid when is_pid(pid) -> {:busy, pid}
          :undefined -> do_acquire(name, conn, attempts - 1)
        end
    end
  end

  @doc "Release `soffice_id` if `conn` holds it, waking waiting queues."
  @spec release(soffice_id(), pid()) :: :ok
  def release(soffice_id, conn) do
    name = {__MODULE__, soffice_id}

    if :global.whereis_name(name) == conn do
      :global.unregister_name(name)
      local = :pg.get_local_members(__MODULE__, :queues)
      remote = :pg.get_members(__MODULE__, :queues) -- local
      for q <- remote ++ local, do: send(q, :lease_released)
    end

    :ok
  end

  # On a partition heal where two nodes leased the same soffice, keep one
  # deterministically without killing either connection process.
  @doc false
  @spec keep(term(), pid(), pid()) :: pid()
  def keep(_name, pid1, pid2), do: if(node(pid1) <= node(pid2), do: pid1, else: pid2)
end

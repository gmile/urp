defmodule URP.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      URP.Lease,
      {DynamicSupervisor, strategy: :one_for_one, name: URP.PoolSupervisor},
      {NimbleOwnership, name: URP.Test.Ownership}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: URP.Supervisor)
  end
end

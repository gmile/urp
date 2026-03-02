defmodule URP.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    config = Application.get_env(:urp, :default, [])

    children = [
      {NimblePool,
       worker:
         {URP.Pool,
          %{
            host: Keyword.get(config, :host, "localhost"),
            port: Keyword.get(config, :port, 2002)
          }},
       pool_size: Keyword.get(config, :pool_size, 1),
       lazy: true,
       name: URP.Pool.Default},
      {DynamicSupervisor, strategy: :one_for_one, name: URP.PoolSupervisor},
      {NimbleOwnership, name: URP.Test.Ownership}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: URP.Supervisor)
  end
end

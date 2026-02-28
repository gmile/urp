defmodule URP.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {NimblePool,
       worker: {URP.Pool, default_pool_config()},
       pool_size: default_pool_size(),
       lazy: true,
       name: URP.Pool.Default},
      {DynamicSupervisor, strategy: :one_for_one, name: URP.PoolSupervisor},
      {NimbleOwnership, name: URP.Test.Ownership}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: URP.Supervisor)
  end

  defp default_pool_config do
    config = Application.get_env(:urp, :default, [])

    %{
      host: Keyword.get(config, :host, "localhost"),
      port: Keyword.get(config, :port, 2002)
    }
  end

  defp default_pool_size do
    config = Application.get_env(:urp, :default, [])
    Keyword.get(config, :pool_size, 1)
  end
end

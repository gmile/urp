defmodule URP.MixProject do
  use Mix.Project

  def project do
    [
      app: :urp,
      version: "0.1.0",
      elixir: "~> 1.19",
      description:
        "Pure Elixir client for the UNO Remote Protocol — convert documents via LibreOffice over TCP",
      package: package(),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      dialyzer: [
        plt_add_apps: [:crypto],
        plt_local_path: "priv/plts",
        plt_core_path: "priv/plts"
      ]
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/gmile/urp"}
    ]
  end

  defp deps do
    [
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false}
    ]
  end

  def application do
    [extra_applications: [:crypto]]
  end
end

defmodule URP.MixProject do
  use Mix.Project

  @version File.read!("VERSION") |> String.trim()

  def project do
    [
      app: :urp,
      version: @version,
      elixir: "~> 1.19",
      description:
        "Pure Elixir client for the UNO Remote Protocol — convert documents via LibreOffice over TCP",
      package: package(),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      docs: docs(),
      dialyzer: [
        plt_add_apps: [:crypto, :mix],
        plt_local_path: "priv/plts",
        plt_core_path: "priv/plts"
      ]
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "CHANGELOG.md"]
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/gmile/urp"},
      files: ~w(lib .formatter.exs mix.exs VERSION README.md LICENSE CHANGELOG.md)
    ]
  end

  defp deps do
    [
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
      {:nimble_ownership, "~> 1.0", optional: true},
      {:nimble_pool, "~> 1.1"}
    ]
  end

  def application do
    [extra_applications: [:crypto]]
  end
end

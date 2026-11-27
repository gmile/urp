defmodule URP.MixProject do
  use Mix.Project

  @version File.read!("VERSION") |> String.trim()

  def project do
    [
      app: :urp,
      version: @version,
      elixir: "~> 1.20",
      description:
        "Pure Elixir client for the UNO Remote Protocol — convert documents via LibreOffice over TCP",
      package: package(),
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      docs: docs(),
      dialyzer: [
        plt_add_apps: [:crypto, :mix],
        plt_local_path: "_build/plts",
        plt_core_path: "_build/plts"
      ]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "PERFORMANCE.md", "CHANGELOG.md", "LICENSE"],
      # Past entries name modules that are internal now.
      skip_undefined_reference_warnings_on: ["CHANGELOG.md"]
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/gmile/urp"},
      files: ~w(lib .formatter.exs mix.exs VERSION README.md PERFORMANCE.md LICENSE CHANGELOG.md)
    ]
  end

  defp deps do
    [
      {:dialyxir, "~> 1.4", only: :dev, runtime: false},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
      {:nimble_options, "~> 1.1"},
      {:nimble_ownership, "~> 1.0"},
      {:telemetry, "~> 1.0"}
    ]
  end

  def application do
    [
      extra_applications: [:crypto, :logger],
      mod: {URP.Application, []}
    ]
  end
end

defmodule Atheum.MixProject do
  use Mix.Project

  def project,
    do: [
      app: :atheum,
      version: "0.1.0",
      elixir: "~> 1.20",
      elixirc_options: [warnings_as_errors: true],
      deps: deps(),
      dialyzer: [
        plt_file: {:no_warn, ".cache/plts/atheum.plt"},
        plt_core_path: ".cache/plts",
        plt_add_apps: [:mix, :crypto]
      ]
    ]

  defp deps do
    [
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  def application, do: [extra_applications: [:crypto]]
end

defmodule Gobusgo.MixProject do
  use Mix.Project

  def project do
    [
      app: :gobusgo,
      version: "0.1.0",
      elixir: "~> 1.20",
      elixirc_options: [warnings_as_errors: true],
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      releases: releases()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {Gobusgo.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_environment), do: ["lib"]

  defp deps do
    [
      {:req, "~> 0.7.4"},
      {:phoenix, "~> 1.8.15"},
      {:phoenix_live_view, "~> 1.2"},
      {:phoenix_html, "~> 4.3"},
      {:bandit, "~> 1.12"},
      {:plug, "~> 1.16"},
      {:broadway_kafka, "~> 0.7.0"},
      {:brod, "~> 4.7"},
      {:esbuild, "~> 0.10.0", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.5.1", runtime: Mix.env() == :dev},
      {:lazy_html, "~> 0.1", only: :test},
      {:quokka, "~> 2.13", only: [:dev, :test], runtime: false}
    ]
  end

  defp releases do
    [
      gobusgo: [
        include_executables_for: [:unix],
        include_erts: true,
        strip_beams: true
      ]
    ]
  end

  defp aliases do
    [
      "assets.tools": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.setup": ["assets.tools", "compile", "gobusgo.vendor.fetch"],
      "assets.build": ["tailwind default", "esbuild default", "esbuild vendor"],
      "assets.deploy": [
        "tailwind default --minify",
        "esbuild default --minify",
        "esbuild vendor",
        "phx.digest"
      ]
    ]
  end
end

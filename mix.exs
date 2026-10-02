defmodule Gobusgo.MixProject do
  use Mix.Project

  def project do
    [
      app: :gobusgo,
      version: "0.1.0",
      elixir: "~> 1.20",
      elixirc_options: [warnings_as_errors: true],
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {Gobusgo.Application, []}
    ]
  end

  defp deps do
    [
      {:req, "~> 0.7.4"},
      {:phoenix, "~> 1.8.15"},
      {:bandit, "~> 1.12"},
      {:plug, "~> 1.16"}
    ]
  end
end

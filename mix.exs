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
      extra_applications: [:logger],
      mod: {Gobusgo.Application, []}
    ]
  end

  defp deps do
    []
  end
end

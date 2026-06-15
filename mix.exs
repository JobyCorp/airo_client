defmodule AiroClient.MixProject do
  use Mix.Project

  def project do
    [
      app: :airo_client,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      description: "Elixir client for the Airo gateway. Consumed by incogito/orchester.",
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:req, "~> 0.5"},
      {:jason, "~> 1.0"},
      # Plug is only needed for Req.Test-based tests.
      {:plug, "~> 1.0", only: :test}
    ]
  end
end

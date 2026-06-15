defmodule AiroClient.MixProject do
  use Mix.Project

  def project do
    [
      app: :airo_client,
      version: "0.1.0",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      description: "Elixir client for the Airo gateway. Consumed by incogito/orchester.",
      deps: deps()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {AiroClient.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:req, "~> 0.5"},
      {:jason, "~> 1.0"},
      # Realtime relay leg (app → Airo /v1/realtime).
      {:mint_web_socket, "~> 1.0"},
      # Plug + a real WebSocket server are only needed for tests (Req.Test plug;
      # Bandit echo/reject upstreams for the realtime relay).
      {:plug, "~> 1.0", only: :test},
      {:bandit, "~> 1.0", only: :test},
      {:websock_adapter, "~> 0.5", only: :test}
    ]
  end
end

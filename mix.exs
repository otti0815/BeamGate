defmodule ReverseProxy.MixProject do
  use Mix.Project

  def project do
    [
      app: :reverse_proxy,
      version: "0.1.0",
      elixir: "~> 1.16",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      mod: {ReverseProxy.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:phoenix, "~> 1.7.14"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_view, "~> 1.0"},
      {:phoenix_live_reload, "~> 1.5", only: :dev},
      {:bandit, "~> 1.5"},
      {:finch, "~> 0.18"},
      {:jason, "~> 1.4"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.1"},
      {:plug_cowboy, "~> 2.7"}
    ]
  end
end

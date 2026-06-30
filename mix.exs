defmodule TownCrowd.MixProject do
  use Mix.Project

  # A standalone app — it talks to TownSquare over the public WebSocket protocol,
  # exactly like a browser. It needs no changes to (and no code from) the server.
  def project do
    [
      app: :town_crowd,
      version: "0.1.0",
      elixir: "~> 1.16",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: releases()
    ]
  end

  def application do
    [
      mod: {TownCrowd.Application, []},
      extra_applications: [:logger, :crypto]
    ]
  end

  # A self-contained OTP release: `mix release` bundles the BEAM, this app, and its
  # deps into a runnable artifact (see the Dockerfile). config/runtime.exs is
  # evaluated on boot, so one build is configured entirely by the environment.
  defp releases do
    [
      town_crowd: [
        include_executables_for: [:unix]
      ]
    ]
  end

  # No agent framework: OTP *is* the agent framework (that's the whole point).
  #   websockex     — the WS client (the role a browser plays)
  #   jason         — JSON
  #   req           — Cloudflare Workers AI calls (free-tier brains)
  #   req_llm       — provider models (anthropic/openai/…), matching the design site
  #   bandit + plug — the only HTTP surface: /healthz + a bot status page
  #                   (TownCrowd.Status). The app itself is a pure WS client.
  # Bots auto-degrade to stub replies when no keys are set, so it runs key-free.
  defp deps do
    [
      {:websockex, "~> 0.4"},
      {:jason, "~> 1.4"},
      {:req, "~> 0.5"},
      {:req_llm, "~> 1.14"},
      {:bandit, "~> 1.5"},
      {:plug, "~> 1.16"}
    ]
  end
end

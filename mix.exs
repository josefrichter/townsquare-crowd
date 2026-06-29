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
      deps: deps()
    ]
  end

  def application do
    [
      mod: {TownCrowd.Application, []},
      extra_applications: [:logger, :crypto]
    ]
  end

  # No agent framework: OTP *is* the agent framework (that's the whole point).
  #   websockex — the WS client (the role a browser plays)
  #   jason     — JSON
  #   req       — Cloudflare Workers AI calls (free-tier brains)
  #   req_llm   — provider models (anthropic/openai/…), matching the design site
  # Bots auto-degrade to stub replies when no keys are set, so it runs key-free.
  defp deps do
    [
      {:websockex, "~> 0.4"},
      {:jason, "~> 1.4"},
      {:req, "~> 0.5"},
      {:req_llm, "~> 1.14"}
    ]
  end
end

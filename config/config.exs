import Config

config :town_crowd,
  # Where the TownSquare server lives. Point this at the BEAM port (beam/, :8788)
  # or at Caue's Node server — the protocol is identical, so the bots don't care.
  # Overridden in production by TOWNSQUARE_WS_URL (see config/runtime.exs).
  townsquare_ws: "ws://127.0.0.1:8788",

  # `Origin` header sent on the WS handshake, or nil to send none. Dev default: none
  # — TownSquare's allowlist is empty locally, so any origin (or none) is accepted.
  # Overridden in production by TOWNSQUARE_ORIGIN, which must match one of the
  # target server's TOWNSQUARE_ALLOWED_ORIGINS or the handshake is rejected.
  townsquare_origin: nil,

  # The bots' persisted conversation log (JSONL). Swap TownCrowd.Transcript for an
  # SQLite-backed module if you want SQL queries — the interface is log/5 + search/2.
  transcript_path: "crowd_transcript.jsonl",

  # The status server (TownCrowd.Status: /healthz + a plain-text bot status page).
  # Overridden in production by PORT (see config/runtime.exs).
  port: 8080,

  # What each scene is "reading" — bots discuss this instead of small-talking.
  # scene key = the website the widget runs on (its domain).
  #
  # Production source: the live article URL. crowd owns no article files — it fetches
  # the page the widget sits under (single source of truth, always current).
  articles: %{
    "josefrichter.design" => "https://josefrichter.design/townsquare",
    "sorted.plus" => "https://sorted.plus/crowd"
  },

  # Dev override: when these local files exist they win over the URL above, so you can
  # edit the article and the bots read your local copy. In the standalone repo (files
  # absent) this simply falls through to the URLs. Safe to delete after the split.
  article_files: %{
    "josefrichter.design" => "../article.html",
    "sorted.plus" => "../crowd-article.html"
  }

# Brains are chosen per-persona by the `model` string and degrade to stubs when keys
# are absent (no master flag — key presence decides):
#
#   Cloudflare Workers AI (free tier):  export CF_ACCOUNT_ID=... CF_API_TOKEN=...
#       model: "cf:@cf/meta/llama-3.1-8b-instruct"
#   Providers via req_llm:              export ANTHROPIC_API_KEY=... (etc.)
#       model: "anthropic:claude-haiku-4-5"
#
# Personas default to TownCrowd.Personas.defaults/0; override the population here:
#
#   config :town_crowd, personas: [
#     %{name: "Llama (CF)", handle: "llama", model: "cf:@cf/meta/llama-3.1-8b-instruct",
#       color: "#8a5fb1", site_key: "default", system: "…", tempo_ms: 12_000}
#   ]

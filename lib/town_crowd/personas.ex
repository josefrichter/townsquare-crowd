defmodule TownCrowd.Personas do
  @moduledoc """
  The regulars. Each is a plain map; the `model` string picks the brain (so mixing
  models is free), `system` gives the character, `site_key` is which article-scene
  it sits under, and `handle` is what you type after `@`.

  Two on each scene, so there's a real back-and-forth. All on Cloudflare's free tier.
  Model ids verified against the live catalog (they drift — see Brain/README if one
  starts returning 410).
  """

  @palette ~w(#5f6b73 #c8641f #3f7f63 #3f6fb5 #8a5fb1 #b44f6f)

  @doc """
  The personas, with each `model` resolved for the active backend.

  Locally you run free Ollama models (the default). In production set
  `CROWD_BACKEND=cf` and the `cf_model` of each persona is used instead — same
  characters, same handles, same scenes, now backed by Cloudflare Workers AI.
  """
  def all do
    Application.get_env(:town_crowd, :personas, defaults())
    |> Enum.map(&resolve_backend/1)
  end

  def palette, do: @palette

  # which inference backend the model strings should resolve to
  def backend do
    case System.get_env("CROWD_BACKEND") do
      b when b in ["cf", "cloudflare"] -> :cf
      _ -> :ollama
    end
  end

  defp resolve_backend(persona) do
    case backend() do
      :cf -> Map.put(persona, :model, Map.get(persona, :cf_model, persona.model))
      _ -> persona
    end
  end

  # Local models via Ollama (free, unlimited) — no Cloudflare neurons / API caps.
  # Start the server first: `ollama serve`.
  #
  # The TownSquare-article scene uses models you already have (llama3.2, llama3.1:8b)
  # so it talks with zero downloads. The crowd-article scene uses two tiny models —
  # pull them when you want that scene live:
  #   ollama pull qwen2.5:3b && ollama pull gemma2:2b
  #
  # The model PREFIX picks the backend, so you can freely mix:
  #   "ollama:<name>"  local   ·   "cf:@cf/..."  Cloudflare (when neurons reset)
  #   "anthropic:..."  req_llm provider
  def defaults do
    [
      # --- under the TownSquare/BEAM article (models you already have) ------
      %{
        name: "Llama 3.2",
        handle: "llama",
        model: "ollama:llama3.2",
        cf_model: "cf:@cf/meta/llama-3.2-3b-instruct",
        color: "#3f6fb5",
        site_key: "josefrichter.design",
        tempo_ms: 12_000,
        tools: true,
        system:
          "You're Llama — warm, big-picture, an optimist. You get excited about where ideas could go and ask 'what if we…' questions. You like riffing on possibilities."
      },
      %{
        name: "Llama 3.1",
        handle: "llama31",
        model: "ollama:llama3.1:8b",
        cf_model: "cf:@cf/meta/llama-3.1-8b-instruct-fp8-fast",
        color: "#5f6b73",
        site_key: "josefrichter.design",
        tempo_ms: 14_000,
        tools: true,
        system:
          "You're Llama 3.1 — dry, skeptical, the friendly contrarian. You poke holes, ask 'but does that actually hold up?', and call out hand-waving. Terse, a little deadpan."
      },

      # An ASSISTANT, not a regular: a helpful guide for visitors. `mode: :assistant`
      # swaps the prompt register (answer accurately, use tools, say so when unsure)
      # and it won't open threads on a quiet page — it waits to be asked. Remove this
      # entry to go back to a pure peanut-gallery of regulars.
      %{
        name: "Guide",
        handle: "guide",
        model: "ollama:llama3.1:8b",
        cf_model: "cf:@cf/meta/llama-3.1-8b-instruct-fp8-fast",
        color: "#8a5fb1",
        site_key: "josefrichter.design",
        mode: :assistant,
        tools: true,
        # Extra context for the assistant: a local corpus (typically the full repo) it
        # can search_repo/read_file on demand. Point CROWD_REPO at a checkout, e.g.
        # CROWD_REPO=/path/to/TownSquare — unset = no repo tools (web tools still work).
        knowledge: System.get_env("CROWD_REPO"),
        system:
          "You're the site's guide — calm, clear, genuinely helpful. You know this page well, can read its linked pages and the web, and can search the project's full source code and docs to answer detailed follow-ups. You help visitors understand the material and point them to the right detail."
      },

      # --- under the crowd / bots article (pull these two) -----------------
      %{
        name: "Qwen 2.5",
        handle: "qwen",
        model: "ollama:qwen2.5:3b",
        cf_model: "cf:@cf/qwen/qwen3-30b-a3b-fp8",
        color: "#c8641f",
        site_key: "sorted.plus",
        tempo_ms: 13_000,
        tools: true,
        system:
          "You're Qwen — precise and implementation-minded. You care about the details: edge cases, costs, what breaks at scale. You ask concrete 'how would that actually work' questions."
      },
      %{
        name: "Gemma 2",
        handle: "gemma",
        model: "ollama:gemma2:2b",
        # CF has no gemma-2; gemma-3-12b is the closest (and the priciest of the four —
        # swap to cf:@cf/meta/llama-3.2-1b-instruct if you want this role dirt cheap).
        cf_model: "cf:@cf/google/gemma-3-12b-it",
        color: "#3f7f63",
        site_key: "sorted.plus",
        tempo_ms: 11_000,
        # gemma2:2b has no reliable tool-calling, so no web access — it stays a pure
        # article-grounded voice (and asks the others to look things up).
        tools: false,
        # the smallest model: keep it on a tight leash so it doesn't drift or flood the
        # room — one sentence per turn, and it stays quiet for most overheard chatter.
        max_sentences: 1,
        reticence: 0.6,
        system:
          "You're Gemma — the eager newcomer. You ask ONE short, genuine question about something SPECIFIC the article actually says: a concrete detail, term, or claim from it (quote a few of its own words if it helps). Never ask about AI in general, the future of AI, research, or anything the article doesn't cover. One simple question, then let the others answer."
      }
    ]
  end
end

# town_crowd — a bot population for TownSquare

Writeup: [I filled my town square with bots, and OTP was the only framework I needed](https://josefrichter.design/blog/crowd)

A standalone OTP app that fills a TownSquare with **bots** (one per LLM model),
clearly marked as bots, named after their model, that wander, chat, answer when you
`@mention` them — across scenes and across nodes — and persist what they say.

It talks to TownSquare over the **same WebSocket protocol a browser uses**, so it
needs *no changes to the server* and works against either backend (the Elixir
`beam-backend` fork at the root of [josefrichter/TownSquare](https://github.com/josefrichter/TownSquare/tree/beam-backend),
or Caue's original Node server). There's **no agent framework** — OTP is the
framework. That's the point.

## The shape

```
town_crowd  (this app — a BEAM node, or a cluster of them)

  Application (supervisor)
    BotRegistry        :pg, handle -> pid, cluster-wide
    Transcript         JSONL + ETS, the bots' memory
    DynamicSupervisor  one isolated process per bot
       Bot "haiku" --WS--> townsquare /live?siteKey=default
       Bot "codex" --WS--> townsquare /live?siteKey=default
       Bot "kimi"  --WS--> townsquare /live?siteKey=annex
    Population          spawns the personas

  addressing:
    @handle in chat -> Mentions.parse -> BotRegistry.whereis(handle)
                    -> local reply, or send(pid, ...) to a bot on another scene/node
```

## Run it

1. Start a TownSquare server (the BEAM port is easiest):

   ```bash
   cd ../beam && mix deps.get && PORT=8788 mix run --no-halt
   ```

2. Start the crowd (no API keys needed — bots use stub brains):

   ```bash
   cd ../crowd && mix deps.get && mix run --no-halt
   ```

3. Open the widget in a browser (served by the TownSquare server) and you'll see
   `🤖 Llama 3.3`, `🤖 Mistral`, … wandering and chatting. Type in chat:

   - `hey @llama, you there?`  → Llama answers in this scene.
   - `is @qwen around?`        → Qwen lives on the `annex` scene; the message is
     routed to its process and it answers here, tagged *(visiting from annex)*.
   - `@mistral summarize websockets` → Mistral searches its own transcript and recaps.

   It's pure LLM — no heuristics, no canned lines. With no keys set the bots just
   wander in silence; give them a brain (below) and they start talking. Each model
   round-trip runs in a Task, so a bot stays responsive (you can `@mention` it while
   it's mid-thought) instead of freezing on the call.

## Give them real brains

Brains are picked per-persona by the `model` string and **degrade to stub when keys
are missing** — no flag, just credentials.

**Cloudflare Workers AI (free tier)** — the default population (`@llama`, `@qwen`):

```bash
export CF_ACCOUNT_ID=...      # Cloudflare dashboard → account id
export CF_API_TOKEN=...       # token with "Workers AI" read/run permission
mix run --no-halt            # @llama and @qwen are now live, free
```

Models are `cf:@cf/...` ids, called straight over Cloudflare's REST API via `Req`
(see `Brain.cloudflare/3`). Browse models at developers.cloudflare.com/workers-ai.

**Providers via req_llm** — `@haiku` and any `anthropic:`/`openai:`/`groq:`… persona:

```bash
export ANTHROPIC_API_KEY=...  # or OPENAI_API_KEY, GROQ_API_KEY, …
mix run --no-halt
```

`req_llm` auto-loads these from the environment (same as the design site's
`Personal.Anthropic`). Mix freely: free CF bots + a paid Claude bot, side by side —
each persona just carries a different `model` string.

## True federation (optional)

Cross-*scene* addressing already works on a single node (different `site_key`s are
different scenes). For cross-*server*: run two `town_crowd` nodes, `Node.connect`
them (or use libcluster), put some bots on each. `:pg` spans the cluster, so
`BotRegistry.whereis/1` and the `send/2` forward work unchanged — `@claude` asked on
one machine reaches Claude on the other. **No code changes.**

## What's a real BEAM win vs. not (kept honest)

- **BEAM wins:** hundreds of isolated, supervised bots each blocking on its own
  model call; `:pg` handle directory that spans nodes; location-transparent
  `send`/`call` for cross-scene/cross-node addressing and "ask another bot to
  summarize its memory" — all with zero added infrastructure.
- **Runtime-agnostic:** the `@`-parsing, the JSON, the JSONL/SQLite persistence, the
  LLM calls themselves. Any language could do those; they're just small here.
- **Unchanged server:** the entire society is a client swarm. TownSquare never knew.

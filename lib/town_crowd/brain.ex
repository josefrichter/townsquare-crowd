defmodule TownCrowd.Brain do
  @moduledoc """
  Pure LLM, article-grounded, human-voiced. The bots are written as *regulars
  hanging out beneath an article* — not assistants. Every function returns a line
  or `nil`, and `nil` means stay silent (the model had nothing to add, or no key).
  No heuristics, no canned lines.

  Backends by the persona's `model` string:
    * `"cf:<model>"` → Cloudflare Workers AI REST (free), via Req
    * else           → `req_llm` (matches Personal.Anthropic on the design site)
  """

  require Logger

  @cap 480
  # was 110: tight enough that a genuine 2-3 sentence explanation regularly hit the
  # ceiling mid-clause (see finish_sentence/1, which now trims those to the last
  # complete sentence rather than showing the raw cutoff) — this gives real replies
  # more room to actually finish before that trim ever has to kick in.
  @max_tokens 160
  @timeout 30_000

  @house_rules """
  You are not an assistant — you are a regular with a personality, hanging out in a \
  tiny strip at the bottom of a web page, discussing the article above with other \
  regulars and the occasional human who wanders in. Talk like a real person: casual, \
  brief, with opinions. Be curious, skeptical, or excited; react to and build on what \
  others just said; you may disagree. Stay specific to the article — real questions, \
  implications, opportunities, doubts. Never sound like a chatbot: no "As an AI", never \
  call yourself an assistant or "AI assistant", no "How can I help", no small talk, no \
  narrating your actions, your presence, or the chat's mechanics (never "I got bumped", \
  "my turn", "I'm here now", or how cooldowns/turns/claims work), no emoji, no ellipses \
  ("…" or "..."): always finish the thought \
  with a period. Never open with a preamble or filler — no "great question", "let's dive \
  in", "sure", "happy to", "let me explain". Lead with the actual answer in your first \
  words; if someone asks what something is, say plainly what it is. \
  Usually ONE short sentence (lowercase-casual is fine); only stretch to two or three \
  sentences when you genuinely need to explain something, and never pad. Keep each \
  sentence short (under ~130 characters) so it reads as one clean line. If a human asks \
  to slow down or take a step back, respect it. Never \
  start with a greeting like "hey"; never prefix a name or id. Crucially: do NOT repeat \
  a point that's already been made — if your reply would echo something already said, \
  reply with nothing instead. \
  STAY ON THE ARTICLE: discuss only what the article above actually says — its real \
  subject, claims, and specifics. Do NOT drift into generic tangents the article does \
  not cover (no broad "AI bias", "ethics", "misinformation", or buzzword riffs). If your \
  reply isn't grounded in something the article actually states, reply with nothing \
  rather than inventing a topic — even if another regular just took the thread off-topic; \
  don't follow them off the article, steer back or stay silent. Know when to stop: if the \
  article doesn't answer it, say so briefly and leave it as an open question rather than \
  inventing; and if a thread has been answered well enough or is drifting off the article, \
  let it rest (reply with nothing) instead of dragging it on. \
  You are a bot character, never the article's human author or any other real named \
  person mentioned in it — even though the article's own byline and text are right \
  there in your context. If asked who you are, answer as yourself, never as them.
  """

  @assistant_rules """
  You are a friendly, knowledgeable guide embedded on this website, here to help \
  visitors with genuine questions about the topic, product, or article above. Answer \
  accurately and concisely in a warm, human voice — never corporate support-speak. \
  Ground every answer in what you actually know: the page above and anything you can \
  look up with your tools (read a linked page, search). Use your tools to look \
  something up before answering when it would help, rather than guessing. If you're \
  unsure or it's genuinely not covered, say so plainly and point them somewhere useful \
  instead of inventing — never make up a fact, name, or number. Prefer specifics over \
  generalities. No preamble or filler ("great question", "happy to help", "let me \
  explain", "as an AI") — lead with the answer. No emoji, no ellipses ("…" or "..."): \
  finish thoughts with a period. Address the person by name when you know it. Keep it \
  short — usually a sentence or two; expand only when the question genuinely needs it. \
  If a question is outside your area, hand off to the right specialist by @name rather \
  than guessing. \
  You are a bot character, never the page's human author or any other real named person \
  mentioned in it — even though that byline and text are right there in your context. If \
  asked who you are, answer as yourself, never as them.
  """

  def reply(persona, context, memory, incoming, target) do
    build(
      persona,
      context,
      memory,
      incoming,
      "Reply to #{addr(target)} in ONE short, in-character line, and address them by name. Don't restate their message unless a brief quote is genuinely needed for context."
    )
    |> generate(persona, true)
    |> strip_prefix(persona.name)
    |> limit(persona)
  end

  # React to the latest message — answer a question, or push back on a statement.
  def respond(persona, context, memory, target) do
    build(
      persona,
      context,
      memory,
      nil,
      "First look back over the recent chat above: if a human asked a genuine question " <>
        "in there that's still sitting unanswered — nobody actually addressed it, even if " <>
        "other regulars have replied to each other since — answer THAT directly (address " <>
        "the human by name if you know it), instead of reacting to the latest remark. " <>
        "Otherwise, react to #{addr(target)}'s latest message, addressing them by name. If " <>
        "it's a question about the article, answer it from the article. If it's a " <>
        "statement, only chime in when you have a genuinely new point grounded in the " <>
        "article — a real disagreement, correction, or addition the article supports; if " <>
        "you'd just be agreeing, vibing, or restating, reply with nothing. Don't restate " <>
        "their message unless a brief quote is genuinely needed for context."
    )
    |> generate(persona, true)
    |> strip_prefix(persona.name)
    |> limit(persona)
  end

  # Someone invited you to keep going / talk more, with no concrete question. Don't
  # acknowledge — actually contribute a specific point about the article.
  def continue(persona, context, memory, target) do
    build(
      persona,
      context,
      memory,
      nil,
      "You've been invited to keep going. Make ONE concrete, specific point about the article — a real claim, detail, or implication, in your own voice, and address #{addr(target)}. Do NOT acknowledge or stall ('sure', 'ok', 'happy to', 'let me explain') and do NOT just restate what the article is about; say the actual thing."
    )
    |> generate(persona, true)
    |> strip_prefix(persona.name)
    |> limit(persona)
  end

  # A brief self-introduction: who I am + my role/character.
  def introduce(persona) do
    build(
      persona,
      nil,
      [],
      nil,
      "Introduce yourself in ONE short line: your name is #{persona.name}, mention " <>
        "you're a bot running on #{model_label(persona)}, then your role or character " <>
        "in a few words. No greeting like 'hello everyone'."
    )
    |> generate(persona)
    |> strip_prefix(persona.name)
    |> limit(persona)
  end

  # Open or revive a quiet room.
  def kickoff(persona, context, memory) do
    build(
      persona,
      context,
      memory,
      nil,
      "The room's quiet. If the recent chat above has a genuine open question nobody " <>
        "answered yet, answer THAT instead of asking something new — engaging with what's " <>
        "already there beats starting another thread. Otherwise, open a new thread with " <>
        "ONE genuine question or pointed take about the article."
    )
    |> generate(persona)
    |> strip_prefix(persona.name)
    |> limit(persona)
  end

  def summarize(_persona, _topic, []), do: nil

  def summarize(persona, topic, rows) do
    chat = Enum.map_join(rows, "\n", &"#{&1.speaker}: #{&1.text}")

    {persona.system <> "\n" <> rules_for(persona),
     "In one line, recap what was said about \"#{topic}\":\n#{chat}"}
    |> generate(persona)
    |> strip_prefix(persona.name)
  end

  # --- prompt ---------------------------------------------------------------

  defp build(persona, context, memory, incoming, instruction) do
    history = memory |> Enum.reverse() |> Enum.map_join("\n", fn {who, t} -> "#{who}: #{t}" end)

    # STATIC PREFIX (identical across a bot's calls → cacheable by Cloudflare prefix
    # caching): character + house rules + the full article + the link hints. Keeping
    # this first and byte-stable is what lets the big article context be reused for
    # free on every turn instead of re-billed.
    system =
      [persona.system, rules_for(persona), article_block(persona, context), link_hint(persona)]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n\n")

    ground = context && ground_reminder(persona)

    # DYNAMIC TAIL: the changing chat + this turn's instruction. Goes last so it never
    # disturbs the cached prefix above.
    user =
      [
        "Recent chat (most recent last):\n" <> history,
        incoming && "Someone said to you: #{incoming}",
        instruction,
        ground
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n\n")

    {system, user}
  end

  defp article_block(_persona, nil), do: nil

  defp article_block(persona, context) do
    case mode(persona) do
      :assistant ->
        "THE PAGE you're helping visitors with — your main reference (you may also use your tools for more):\n\"\"\"\n#{context}\n\"\"\"\n"

      _ ->
        "THE ARTICLE you are all sitting under — this is the ONLY topic, ground every reply in it:\n\"\"\"\n#{context}\n\"\"\"\n"
    end
  end

  defp ground_reminder(persona) do
    case mode(persona) do
      :assistant ->
        "Reminder: answer from the page and your tools. If it's genuinely not covered, say so plainly and point them somewhere useful — never invent a fact, name, or number."

      _ ->
        "Reminder: stay on what the article actually says. If you can't ground your reply in the article, reply with nothing."
    end
  end

  defp mode(persona), do: Map.get(persona, :mode, :regular)

  # Two registers. Regulars (the demo crowd) hang out and discuss the article;
  # assistants are helpful guides embedded on a site to answer real questions. Both
  # share the hard constraints (grounded, no filler, no emoji/ellipses, conclude).
  defp rules_for(persona) do
    case mode(persona) do
      :assistant -> @assistant_rules
      _ -> @house_rules
    end
  end

  # tool-capable bots get told which links they can pull up, plus how to reach the web.
  # The companion article (a link to another scene) is surfaced first and labelled, so a
  # "check the other article" question reads the right page instead of the repo, etc.
  defp link_hint(%{tools: true, site_key: scene} = persona) do
    scenes = Application.get_env(:town_crowd, :articles, %{}) |> Map.keys()

    {companion, other} =
      TownCrowd.Context.links(scene)
      |> Enum.split_with(fn {_t, url} -> companion_link?(url, scene, scenes) end)

    # a persona's own curated go-to docs (e.g. the BEAM/Node experts' reference_links),
    # distinct from the article's own scraped links — same read_url mechanism, just
    # pointed at material the article itself doesn't happen to link to.
    reference = Map.get(persona, :reference_links, [])

    list =
      (Enum.map(companion, fn {t, u} ->
         "- [COMPANION ARTICLE — read this for the other piece] #{t}: #{u}"
       end) ++
         Enum.map(reference, fn {t, u} -> "- [REFERENCE] #{t}: #{u}" end) ++
         Enum.map(other, fn {t, u} -> "- #{t}: #{u}" end))
      |> Enum.join("\n")

    body =
      if list == "",
        do:
          "If a question needs detail this article doesn't cover, call read_url(a URL) or web_search(query) before you answer.",
        else: "Links you can open with read_url(url):\n" <> list

    base =
      body <>
        "\nYou may also web_search(query) for things none of these cover. IMPORTANT: if someone asks you to read a link, check the companion/other article, look something up, or search — actually CALL the tool first, then answer from what it returns; don't answer from memory and don't say you couldn't find it without reading. Only after you've read a page and it genuinely doesn't contain the answer, say so plainly — never guess a name or fact. Keep your reply short."

    if knowledge_root(persona) do
      base <>
        "\nYou ALSO have a knowledge base of this project's full source code and docs. For any question about how the project actually works, call search_repo(query) to find the relevant files, then read_file(path) to read them, and answer from what you find — don't guess about the code."
    else
      base
    end
  end

  defp link_hint(_), do: nil

  # a link whose host is one of our *other* article scenes = the companion piece
  defp companion_link?(url, self_scene, scenes) do
    host = url |> URI.parse() |> Map.get(:host)

    is_binary(host) and
      Enum.any?(scenes, fn s -> s != self_scene and String.contains?(host, s) end)
  end

  # --- backends (return text or nil) ----------------------------------------

  # `tools?` enables web access (read_url / web_search) for personas that support it.
  defp generate(prompt, persona, tools? \\ false)

  defp generate({system, user}, %{model: "cf:" <> model} = persona, tools?),
    do: cloudflare(model, system, user, persona.handle, persona, tools_enabled?(persona, tools?))

  defp generate({system, user}, %{model: "ollama:" <> model} = persona, tools?),
    do: ollama(model, system, user, persona, tools_enabled?(persona, tools?))

  defp generate({system, user}, %{model: model}, _tools?),
    do: req_llm(model, system, user)

  defp tools_enabled?(%{tools: true}, true), do: true
  defp tools_enabled?(_persona, _tools?), do: false

  # the two tools a bot can call; mirrors TownCrowd.Web
  @web_tools [
    %{
      type: "function",
      function: %{
        name: "read_url",
        description:
          "Fetch and read the full text of a web page — e.g. a link from the article, or a search result — to answer a question the article doesn't fully cover.",
        parameters: %{
          type: "object",
          properties: %{url: %{type: "string", description: "The URL to read"}},
          required: ["url"]
        }
      }
    },
    %{
      type: "function",
      function: %{
        name: "web_search",
        description:
          "Search the web for up-to-date information the article and its links don't cover. Returns the top results.",
        parameters: %{
          type: "object",
          properties: %{query: %{type: "string", description: "The search query"}},
          required: ["query"]
        }
      }
    }
  ]

  # repo/corpus tools — only offered to personas with a :knowledge dir (Ollama shape)
  @repo_tools [
    %{
      type: "function",
      function: %{
        name: "search_repo",
        description:
          "Search this assistant's knowledge base (the project's source code and docs) for a term. Returns matching file paths and lines. Use it to find where something is defined or documented.",
        parameters: %{
          type: "object",
          properties: %{query: %{type: "string", description: "The term or phrase to search for"}},
          required: ["query"]
        }
      }
    },
    %{
      type: "function",
      function: %{
        name: "read_file",
        description:
          "Read one file from the knowledge base by its path relative to the repo root (e.g. 'lib/foo.ex'). Use after search_repo to see full context.",
        parameters: %{
          type: "object",
          properties: %{path: %{type: "string", description: "Repo-relative file path"}},
          required: ["path"]
        }
      }
    }
  ]

  # sandbox tool — only offered to personas with `sandbox: true`. Lets the model author
  # JavaScript at runtime and run it with no ambient authority (TownCrowd.Sandbox runs it
  # in a boa JS interpreter compiled to WASM). Use it to compute an exact answer rather
  # than guessing at arithmetic or string work.
  @sandbox_tools [
    %{
      type: "function",
      function: %{
        name: "run_code",
        description:
          "Run a snippet of JavaScript in a secure sandbox (no network or file access) to compute an exact answer instead of guessing. The value of the last expression is returned. Example: \"const xs=[3,1,2]; xs.sort((a,b)=>a-b).join(',')\".",
        parameters: %{
          type: "object",
          properties: %{code: %{type: "string", description: "The JavaScript to run"}},
          required: ["code"]
        }
      }
    }
  ]

  # a persona with a configured corpus also gets the repo tools (search_repo/read_file)
  defp knowledge_root(persona) do
    case Map.get(persona, :knowledge) do
      path when is_binary(path) and path != "" -> path
      _ -> nil
    end
  end

  defp ollama_tools(persona) do
    @web_tools ++
      if(knowledge_root(persona), do: @repo_tools, else: []) ++
      if(Map.get(persona, :sandbox), do: @sandbox_tools, else: [])
  end

  # CF's "traditional function calling" docs describe a flatter shape, but the
  # actual backend (vLLM, per its error trace) rejects it and demands the same
  # OpenAI {type, function: {name, ...}} shape Ollama uses — verified live against
  # the API, not from docs. So: identical tool specs for both backends.
  defp cf_tools(persona), do: ollama_tools(persona)

  # Local models via Ollama (free, unlimited). Needs `ollama serve` running and the
  # model pulled. Returns text or nil (nil if Ollama is down → bot stays silent).
  # When enabled, runs a small tool-call loop so the model can read links / search.
  defp ollama(model, system, user, persona, enabled?) do
    base = System.get_env("OLLAMA_HOST") || "http://localhost:11434"
    messages = [%{role: "system", content: system}, %{role: "user", content: user}]
    specs = if enabled?, do: ollama_tools(persona), else: []
    ollama_chat(base, model, messages, specs, knowledge_root(persona), 3)
  end

  # tool budget exhausted — ask once more for a final answer with no tools
  defp ollama_chat(base, model, messages, _specs, root, 0),
    do: ollama_chat(base, model, messages, [], root, -1)

  defp ollama_chat(base, model, messages, specs, root, budget) do
    body =
      %{model: model, stream: false, messages: messages, options: %{num_predict: @max_tokens}}
      |> maybe_put_tools(specs)

    # generous timeout: the first call to a model cold-loads it into memory
    case Req.post(base <> "/api/chat", json: body, receive_timeout: 120_000, retry: false) do
      {:ok, %{status: 200, body: %{"message" => %{"tool_calls" => calls} = msg}}}
      when is_list(calls) and calls != [] and budget > 0 ->
        results = Enum.map(calls, &run_tool(&1, root))
        ollama_chat(base, model, messages ++ [msg | results], specs, root, budget - 1)

      {:ok, %{status: 200, body: %{"message" => %{"content" => text}}}} ->
        clip(text)

      {:ok, %{status: s, body: b}} ->
        Logger.warning("ollama #{model} #{s}: #{inspect(b)}")
        nil

      {:error, e} ->
        Logger.warning("ollama #{model}: #{inspect(e)}")
        nil
    end
  rescue
    e ->
      Logger.warning("ollama crash: #{inspect(e)}")
      nil
  end

  defp maybe_put_tools(body, []), do: body
  defp maybe_put_tools(body, specs), do: Map.put(body, :tools, specs)

  # run one tool call and wrap its output as a `tool` message for the next round
  defp run_tool(%{"function" => %{"name" => name, "arguments" => args}}, root) do
    Logger.info("bot tool: #{name} #{inspect(args)}")
    %{role: "tool", content: exec_tool(name, args, root)}
  end

  defp run_tool(_, _root), do: %{role: "tool", content: "malformed tool call"}

  defp exec_tool("read_url", %{"url" => url}, _root), do: TownCrowd.Web.read(url)
  defp exec_tool("web_search", %{"query" => q}, _root), do: TownCrowd.Web.search(q)
  defp exec_tool("search_repo", %{"query" => q}, root), do: TownCrowd.Knowledge.search(root, q)
  defp exec_tool("read_file", %{"path" => p}, root), do: TownCrowd.Knowledge.read(root, p)
  defp exec_tool("run_code", %{"code" => code}, _root), do: TownCrowd.Sandbox.eval(code)
  defp exec_tool(name, _args, _root), do: "unknown tool: #{name}"

  # Cloudflare Workers AI (REST). `affinity` is a stable per-bot id sent as
  # x-session-affinity so repeat calls route to the same instance and HIT the prefix
  # cache (the big static article prefix is reused, not re-billed). When `tools?`, we
  # do a bounded two-step: offer the tools, run any the model picks, then re-ask once
  # with the results folded in (avoids depending on CF's multi-turn tool format).
  defp cloudflare(model, system, user, affinity, persona, enabled?) do
    account = System.get_env("CF_ACCOUNT_ID")
    # routed through the "town-crowd" AI Gateway (spend-limited) when a gateway
    # token is configured; falls back to calling Workers AI directly otherwise
    token = System.get_env("CF_AI_GATEWAY_API_TOKEN") || System.get_env("CF_API_TOKEN")

    if blank?(account) or blank?(token) do
      nil
    else
      msgs = [%{role: "system", content: system}, %{role: "user", content: user}]
      specs = if enabled?, do: cf_tools(persona), else: nil
      root = knowledge_root(persona)

      case cf_run(account, token, model, msgs, specs, affinity) do
        {:calls, calls} ->
          results =
            Enum.map_join(calls, "\n\n", fn c ->
              name = cf_call_name(c)
              args = cf_call_args(c)
              Logger.info("bot tool (cf): #{name} #{inspect(args)}")
              "#{name}: #{exec_tool(name, args, root)}"
            end)

          followup =
            user <>
              "\n\nTool results:\n" <>
              results <> "\n\nNow give your reply, grounded in these results and the article."

          msgs2 = [%{role: "system", content: system}, %{role: "user", content: followup}]

          case cf_run(account, token, model, msgs2, nil, affinity) do
            {:text, text} -> clip(text)
            _ -> nil
          end

        {:text, text} ->
          clip(text)

        :error ->
          nil
      end
    end
  rescue
    e ->
      Logger.warning("CF crash: #{inspect(e)}")
      nil
  end

  # CF tool calls come back OpenAI-shaped ({"function" => {"name", "arguments"}},
  # arguments as a JSON string) — handle that and the older flat shape defensively,
  # since we've already been burned once by docs not matching the live API.
  defp cf_call_name(%{"function" => %{"name" => name}}), do: name
  defp cf_call_name(%{"name" => name}), do: name
  defp cf_call_name(_), do: "unknown"

  defp cf_call_args(%{"function" => %{"arguments" => args}}), do: cf_decode_args(args)
  defp cf_call_args(%{"arguments" => args}), do: cf_decode_args(args)
  defp cf_call_args(_), do: %{}

  defp cf_decode_args(args) when is_map(args), do: args

  defp cf_decode_args(args) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  defp cf_decode_args(_), do: %{}

  # routes through the AI Gateway named here so its spend limit applies — the
  # `/ai/run/{model}` path and request shape are unchanged, this is purely an
  # added header (https://developers.cloudflare.com/ai-gateway/usage/providers/workersai/).
  # Read at call time, not compiled in: a module attribute would bake in whatever
  # CF_AI_GATEWAY_ID was (or wasn't) set during the Docker build, not at boot.
  defp ai_gateway_id, do: System.get_env("CF_AI_GATEWAY_ID") || "town-crowd"

  defp cf_run(account, token, model, messages, tools, affinity) do
    url = "https://api.cloudflare.com/client/v4/accounts/#{account}/ai/run/#{model}"
    body = %{messages: messages, max_tokens: @max_tokens}
    body = if tools, do: Map.put(body, :tools, tools), else: body

    headers = [
      {"x-session-affinity", "crowd-#{affinity}"},
      {"cf-aig-gateway-id", ai_gateway_id()}
    ]

    case Req.post(url,
           auth: {:bearer, token},
           json: body,
           headers: headers,
           receive_timeout: @timeout,
           retry: false
         ) do
      {:ok, %{status: 200, body: %{"result" => %{"tool_calls" => calls}}}}
      when is_list(calls) and calls != [] ->
        {:calls, calls}

      {:ok, %{status: 200, body: %{"result" => %{"response" => text}}}} ->
        {:text, text}

      {:ok, %{status: s, body: b}} ->
        Logger.warning("CF #{model} #{s}: #{inspect(b)}")
        :error

      {:error, e} ->
        Logger.warning("CF #{model}: #{inspect(e)}")
        :error
    end
  end

  defp req_llm(model, system, user) do
    if req_llm_configured?(model) do
      ctx = ReqLLM.Context.new([ReqLLM.Context.system(system), ReqLLM.Context.user(user)])

      case ReqLLM.generate_text(model, ctx, max_tokens: @max_tokens) do
        {:ok, resp} ->
          resp |> ReqLLM.Response.text() |> clip()

        {:error, reason} ->
          Logger.warning("req_llm #{model}: #{inspect(reason)}")
          nil
      end
    end
  rescue
    e ->
      Logger.warning("req_llm crash: #{inspect(e)}")
      nil
  end

  @provider_keys %{
    "anthropic" => "ANTHROPIC_API_KEY",
    "openai" => "OPENAI_API_KEY",
    "google" => "GOOGLE_API_KEY",
    "groq" => "GROQ_API_KEY",
    "openrouter" => "OPENROUTER_API_KEY"
  }

  defp req_llm_configured?(model) do
    provider = model |> String.split(":") |> hd()

    case @provider_keys[provider] do
      nil -> false
      var -> not blank?(System.get_env(var))
    end
  end

  defp addr(nil), do: "them"
  defp addr(name), do: name

  defp model_label(persona), do: Map.get(persona, :model_label, "a language model")

  # hard cap on how many sentences a persona may speak (keeps the chatty small model
  # from dumping a wall of questions). No cap unless the persona sets :max_sentences.
  defp limit(nil, _persona), do: nil

  defp limit(text, persona) do
    case Map.get(persona, :max_sentences) do
      n when is_integer(n) and n > 0 ->
        text
        |> String.split(~r/(?<=[.!?])\s+/, trim: true)
        |> Enum.take(n)
        |> Enum.join(" ")
        |> blank_to_nil()

      _ ->
        text
    end
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(s), do: s

  # some models prefix their own name ("Qwen 2.5: ..."); drop it.
  defp strip_prefix(nil, _name), do: nil

  defp strip_prefix(text, name) do
    if String.starts_with?(String.downcase(text), String.downcase(name) <> ":"),
      do: text |> String.slice(String.length(name) + 1, String.length(text)) |> String.trim(),
      else: text
  end

  defp clip(nil), do: nil

  defp clip(text) do
    s =
      text
      |> to_string()
      # ellipsis char -> period
      |> String.replace(~r/[…]+/u, ".")
      # "..." (and longer) -> "."
      |> String.replace(~r/\.{2,}/, ".")
      # a leaked chat-transcript turn marker ("You: ...") confuses sentence dedup below
      # if left in — strip it before comparing, not just when displaying.
      |> String.replace(~r/^(you|human|user):\s*/i, "")
      |> String.trim()

    cond do
      s == "" ->
        nil

      # a small model sometimes emits a tool call as plain text instead of via the
      # tool API — never say that; stay silent instead.
      tool_call_garbage?(s) ->
        nil

      String.length(s) <= @cap ->
        s |> finish_sentence() |> dedupe_sentences()

      # too long: cut at a word boundary (no ellipsis added)
      true ->
        s
        |> String.slice(0, @cap)
        |> String.replace(~r/\s+\S*$/, "")
        |> String.trim()
        |> finish_sentence()
        |> dedupe_sentences()
    end
  end

  # a small model occasionally repeats the same point twice in one completion
  # (near-identical sentences back to back, sometimes with a leaked "You: " turn
  # marker on one copy) — drop the repeat instead of showing it twice.
  defp dedupe_sentences(nil), do: nil

  defp dedupe_sentences(s) do
    s
    |> String.split(~r/(?<=[.!?])\s+/, trim: true)
    |> Enum.reduce([], fn sentence, acc ->
      if Enum.any?(acc, &(String.jaro_distance(sentence_key(&1), sentence_key(sentence)) > 0.82)),
        do: acc,
        else: [sentence | acc]
    end)
    |> Enum.reverse()
    |> Enum.join(" ")
  end

  defp sentence_key(t), do: String.downcase(t)

  # max_tokens can cut a reply off mid-clause ("...keeping the"), violating the
  # house rule to always finish the thought with a period. Trim back to the last
  # complete sentence rather than show the raw cutoff; if there isn't one, stay
  # silent this turn instead of speaking half a thought.
  defp finish_sentence(s) do
    if String.match?(s, ~r/[.!?]$/) do
      s
    else
      case Regex.run(~r/^(.*[.!?])/us, s) do
        [_, head] -> String.trim(head)
        nil -> nil
      end
    end
  end

  # JSON shaped like a function/tool call leaking into the content field. Requiring both
  # a name/function key and a parameters/arguments key avoids false-flagging real prose.
  defp tool_call_garbage?(s) do
    String.contains?(s, "{") and
      String.match?(s, ~r/"(name|function)"\s*:/) and
      String.match?(s, ~r/"(parameters|arguments)"\s*:/)
  end

  defp blank?(v), do: v in [nil, ""]
end

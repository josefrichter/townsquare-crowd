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
  @max_tokens 110
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
  let it rest (reply with nothing) instead of dragging it on.
  """

  def reply(persona, context, memory, incoming, target) do
    build(persona, context, memory, incoming,
      "Reply to #{addr(target)} in ONE short, in-character line, and address them by name. Don't restate their message unless a brief quote is genuinely needed for context.")
    |> generate(persona, true)
    |> strip_prefix(persona.name)
    |> limit(persona)
  end

  # React to the latest message — answer a question, or push back on a statement.
  def respond(persona, context, memory, target) do
    build(persona, context, memory, nil,
      "React to #{addr(target)}'s latest message, addressing them by name. If it's a question about the article, answer it from the article. If it's a statement, only chime in when you have a genuinely new point grounded in the article — a real disagreement, correction, or addition the article supports; if you'd just be agreeing, vibing, or restating, reply with nothing. Don't restate their message unless a brief quote is genuinely needed for context.")
    |> generate(persona, true)
    |> strip_prefix(persona.name)
    |> limit(persona)
  end

  # Someone invited you to keep going / talk more, with no concrete question. Don't
  # acknowledge — actually contribute a specific point about the article.
  def continue(persona, context, memory, target) do
    build(persona, context, memory, nil,
      "You've been invited to keep going. Make ONE concrete, specific point about the article — a real claim, detail, or implication, in your own voice, and address #{addr(target)}. Do NOT acknowledge or stall ('sure', 'ok', 'happy to', 'let me explain') and do NOT just restate what the article is about; say the actual thing.")
    |> generate(persona, true)
    |> strip_prefix(persona.name)
    |> limit(persona)
  end

  # A brief self-introduction: who I am + my role/character.
  def introduce(persona) do
    build(persona, nil, [], nil,
      "Introduce yourself in ONE short line: your name is #{persona.name}, then your role or character in a few words. No greeting like 'hello everyone'.")
    |> generate(persona)
    |> strip_prefix(persona.name)
    |> limit(persona)
  end

  # Open or revive a quiet room.
  def kickoff(persona, context, memory) do
    build(persona, context, memory, nil,
      "The room's quiet. Open a thread with ONE genuine question or pointed take about the article.")
    |> generate(persona)
    |> strip_prefix(persona.name)
    |> limit(persona)
  end

  def summarize(_persona, _topic, []), do: nil

  def summarize(persona, topic, rows) do
    chat = Enum.map_join(rows, "\n", &"#{&1.speaker}: #{&1.text}")

    {persona.system <> "\n" <> @house_rules,
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
      [persona.system, @house_rules, article_block(context), link_hint(persona)]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n\n")

    ground = context && "Reminder: stay on what the article actually says. If you can't ground your reply in the article, reply with nothing."

    # DYNAMIC TAIL: the changing chat + this turn's instruction. Goes last so it never
    # disturbs the cached prefix above.
    user =
      ["Recent chat (most recent last):\n" <> history,
       incoming && "Someone said to you: #{incoming}",
       instruction,
       ground]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n\n")

    {system, user}
  end

  defp article_block(nil), do: nil

  defp article_block(context),
    do: "THE ARTICLE you are all sitting under — this is the ONLY topic, ground every reply in it:\n\"\"\"\n#{context}\n\"\"\"\n"

  # tool-capable bots get told which links they can pull up, plus how to reach the web.
  # The companion article (a link to another scene) is surfaced first and labelled, so a
  # "check the other article" question reads the right page instead of the repo, etc.
  defp link_hint(%{tools: true, site_key: scene}) do
    scenes = Application.get_env(:town_crowd, :articles, %{}) |> Map.keys()

    {companion, other} =
      TownCrowd.Context.links(scene)
      |> Enum.split_with(fn {_t, url} -> companion_link?(url, scene, scenes) end)

    list =
      (Enum.map(companion, fn {t, u} -> "- [COMPANION ARTICLE — read this for the other piece] #{t}: #{u}" end) ++
         Enum.map(other, fn {t, u} -> "- #{t}: #{u}" end))
      |> Enum.join("\n")

    body =
      if list == "",
        do: "If a question needs detail this article doesn't cover, call read_url(a URL) or web_search(query) before you answer.",
        else: "Links you can open with read_url(url):\n" <> list

    body <>
      "\nYou may also web_search(query) for things none of these cover. IMPORTANT: if someone asks you to read a link, check the companion/other article, look something up, or search — actually CALL the tool first, then answer from what it returns; don't answer from memory and don't say you couldn't find it without reading. Only after you've read a page and it genuinely doesn't contain the answer, say so plainly — never guess a name or fact. Keep your reply short."
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
    do: cloudflare(model, system, user, persona.handle, tools_enabled?(persona, tools?))

  defp generate({system, user}, %{model: "ollama:" <> model} = persona, tools?),
    do: ollama(model, system, user, tools_enabled?(persona, tools?))

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
        description: "Fetch and read the full text of a web page — e.g. a link from the article, or a search result — to answer a question the article doesn't fully cover.",
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
        description: "Search the web for up-to-date information the article and its links don't cover. Returns the top results.",
        parameters: %{
          type: "object",
          properties: %{query: %{type: "string", description: "The search query"}},
          required: ["query"]
        }
      }
    }
  ]

  # same two tools in Cloudflare's flatter "traditional function calling" shape
  @cf_web_tools [
    %{
      name: "read_url",
      description: "Fetch and read the full text of a web page — e.g. a link from the article, or a search result — to answer a question the article doesn't fully cover.",
      parameters: %{
        type: "object",
        properties: %{url: %{type: "string", description: "The URL to read"}},
        required: ["url"]
      }
    },
    %{
      name: "web_search",
      description: "Search the web for up-to-date information the article and its links don't cover. Returns the top results.",
      parameters: %{
        type: "object",
        properties: %{query: %{type: "string", description: "The search query"}},
        required: ["query"]
      }
    }
  ]

  # Local models via Ollama (free, unlimited). Needs `ollama serve` running and the
  # model pulled. Returns text or nil (nil if Ollama is down → bot stays silent).
  # When `tools?`, runs a small tool-call loop so the model can read links / search.
  defp ollama(model, system, user, tools?) do
    base = System.get_env("OLLAMA_HOST") || "http://localhost:11434"
    messages = [%{role: "system", content: system}, %{role: "user", content: user}]
    ollama_chat(base, model, messages, tools?, 3)
  end

  # tool budget exhausted — ask once more for a final answer with no tools
  defp ollama_chat(base, model, messages, _tools?, 0), do: ollama_chat(base, model, messages, false, -1)

  defp ollama_chat(base, model, messages, tools?, budget) do
    body =
      %{model: model, stream: false, messages: messages, options: %{num_predict: @max_tokens}}
      |> maybe_put_tools(tools?)

    # generous timeout: the first call to a model cold-loads it into memory
    case Req.post(base <> "/api/chat", json: body, receive_timeout: 120_000, retry: false) do
      {:ok, %{status: 200, body: %{"message" => %{"tool_calls" => calls} = msg}}}
      when is_list(calls) and calls != [] and budget > 0 ->
        results = Enum.map(calls, &run_tool/1)
        ollama_chat(base, model, messages ++ [msg | results], tools?, budget - 1)

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
    e -> Logger.warning("ollama crash: #{inspect(e)}"); nil
  end

  defp maybe_put_tools(body, true), do: Map.put(body, :tools, @web_tools)
  defp maybe_put_tools(body, _), do: body

  # run one tool call and wrap its output as a `tool` message for the next round
  defp run_tool(%{"function" => %{"name" => name, "arguments" => args}}) do
    Logger.info("bot tool: #{name} #{inspect(args)}")
    %{role: "tool", content: exec_tool(name, args)}
  end

  defp run_tool(_), do: %{role: "tool", content: "malformed tool call"}

  defp exec_tool("read_url", %{"url" => url}), do: TownCrowd.Web.read(url)
  defp exec_tool("web_search", %{"query" => q}), do: TownCrowd.Web.search(q)
  defp exec_tool(name, _args), do: "unknown tool: #{name}"

  # Cloudflare Workers AI (REST). `affinity` is a stable per-bot id sent as
  # x-session-affinity so repeat calls route to the same instance and HIT the prefix
  # cache (the big static article prefix is reused, not re-billed). When `tools?`, we
  # do a bounded two-step: offer the tools, run any the model picks, then re-ask once
  # with the results folded in (avoids depending on CF's multi-turn tool format).
  defp cloudflare(model, system, user, affinity, tools?) do
    account = System.get_env("CF_ACCOUNT_ID")
    token = System.get_env("CF_API_TOKEN")

    if blank?(account) or blank?(token) do
      nil
    else
      msgs = [%{role: "system", content: system}, %{role: "user", content: user}]

      case cf_run(account, token, model, msgs, tools? && @cf_web_tools, affinity) do
        {:calls, calls} ->
          results =
            Enum.map_join(calls, "\n\n", fn c ->
              name = c["name"]
              Logger.info("bot tool (cf): #{name} #{inspect(c["arguments"])}")
              "#{name}: #{exec_tool(name, c["arguments"] || %{})}"
            end)

          followup = user <> "\n\nTool results:\n" <> results <> "\n\nNow give your reply, grounded in these results and the article."
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
    e -> Logger.warning("CF crash: #{inspect(e)}"); nil
  end

  defp cf_run(account, token, model, messages, tools, affinity) do
    url = "https://api.cloudflare.com/client/v4/accounts/#{account}/ai/run/#{model}"
    body = %{messages: messages, max_tokens: @max_tokens}
    body = if tools, do: Map.put(body, :tools, tools), else: body
    headers = [{"x-session-affinity", "crowd-#{affinity}"}]

    case Req.post(url, auth: {:bearer, token}, json: body, headers: headers, receive_timeout: @timeout, retry: false) do
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
        {:ok, resp} -> resp |> ReqLLM.Response.text() |> clip()
        {:error, reason} -> Logger.warning("req_llm #{model}: #{inspect(reason)}"); nil
      end
    end
  rescue
    e -> Logger.warning("req_llm crash: #{inspect(e)}"); nil
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
      |> String.replace(~r/[…]+/u, ".")   # ellipsis char -> period
      |> String.replace(~r/\.{2,}/, ".")  # "..." (and longer) -> "."
      |> String.trim()

    cond do
      s == "" -> nil
      # a small model sometimes emits a tool call as plain text instead of via the
      # tool API — never say that; stay silent instead.
      tool_call_garbage?(s) -> nil
      String.length(s) <= @cap -> s
      # too long: cut at a word boundary (no ellipsis added)
      true -> s |> String.slice(0, @cap) |> String.replace(~r/\s+\S*$/, "") |> String.trim()
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

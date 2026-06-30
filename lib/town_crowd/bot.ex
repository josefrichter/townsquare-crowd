defmodule TownCrowd.Bot do
  @moduledoc """
  One bot = one process: a model-named WebSocket avatar that discusses the article
  it sits under, taking human-like conversational turns.

  Human-like pacing (informed by typing-indicator / turn-taking UX research):

    * **Typing dots while thinking** — the moment a bot starts a model round-trip it
      shows the native 3-dot typing indicator, so you can see someone is reacting;
      the dots clear when it speaks (or decides to stay quiet).
    * **Reading time** — before reacting to overheard chat it waits a beat that scales
      with the message length (longer messages take longer to "read").
    * **Yield the floor** — extra pause after a human speaks, so you can keep typing.
    * **Pushback** — if a human says "slow down / wait / step back", the bots go
      deferential for a while (only answer when @mentioned); "go on" resumes them.
    * **Cooldown** — a bot won't speak twice in quick succession.

  Movement: a slow `:step` walks the avatar toward a target (never teleports); when
  it speaks it aims near the last speaker, so a conversation makes bots flock.
  """

  use GenServer
  require Logger

  alias TownCrowd.{Socket, BotRegistry, Mentions, Brain, Transcript, Context, Chunk, Shadow}

  # movement
  @min_x 0.04
  @max_x 0.96
  @walk_step 0.02
  @step_ms 650

  # conversation pacing (human-followable)
  # Slowed down from the original values: with up to 5 bots awake at once, the room's
  # *overall* tempo is the sum of everyone's reactions, not any one bot's cooldown — a
  # short jitter window meant several bots could land replies within the same few
  # seconds, reading as a flood rather than a conversation. Wider jitter and reading
  # time spreads simultaneous reactions out in real time; the rest just slows the
  # per-bot rhythm to something a human can actually read as it arrives.
  @consider_base_ms 3_500
  @read_ms_per_char 55
  @read_cap_ms 12_000
  @human_yield_ms 5_000
  @consider_jitter 7_000
  @cooldown_ms 26_000
  # after this many bot-to-bot turns with no human, let the thread rest until a human
  # speaks (or a quiet-room kickoff) — stops two bots ping-ponging forever
  @bot_streak_max 2
  @quiet_kickoff_ms 45_000
  @kickoff_check_ms 15_000
  @calm_ms 45_000

  # simulated typing after the model returns (the round-trip itself already shows dots)
  @type_ms_per_char 45
  @type_min_ms 900
  @type_max_ms 3_500
  # gap between bubbles of a multi-part reply
  @interchunk_ms 1_800
  # how long a "I'm answering this message" claim holds
  @claim_ttl 25_000

  # one bot acknowledges a human "slow down" out loud, then the room goes quiet
  @ack_min_ms 300
  @ack_jitter 1_400
  @ack_phrases [
    "sure, go ahead.",
    "ok, slowing down.",
    "got it, take your time.",
    "alright, the floor's yours.",
    "fair, i'll hang back."
  ]

  @dedup_keep 64

  @slow_re ~r/\b(slow down|slower|wait|hold on|hang on|pause|stop|step back|too fast|one at a time|let me|give me a (?:sec|second|moment|min)|quiet|chill)\b/i
  @resume_re ~r/\b(go on|continue|carry on|go ahead|keep going|your thoughts|resume)\b/i
  # vague human invitations to keep talking — answer with a concrete point, not "sure"
  @continue_re ~r/\b(go on|go ahead|continue|carry on|keep going|tell me more|talk to me|say more|what else|elaborate|more please)\b/i
  @come_over_re ~r/\b(come over|come here|over here|join us|come join|come to (?:this|our))\b/i
  @intro_re ~r/\b(introduce yoursel(?:f|ves)|who are you|who('?s| is) (?:here|everyone)|tell (?:us|me) about yoursel|what('?s| is) your (?:role|character|deal)|introductions?)\b/i

  def start_link(persona), do: GenServer.start_link(__MODULE__, persona)

  @impl true
  def init(persona) do
    {:ok, sock} =
      Socket.start_link(%{
        owner: self(),
        url: TownCrowd.ws_url(persona.site_key),
        origin: TownCrowd.origin()
      })

    BotRegistry.register(persona.handle)
    BotRegistry.join_scene(persona.site_key)
    x = rand_x()

    state = %{
      persona: persona,
      sock: sock,
      scene: persona.site_key,
      context: Context.article(persona.site_key),
      browser_id: gen_id(),
      secret: nil,
      x: x,
      target: x,
      color: st_color(persona),
      offset: (:erlang.phash2(persona.handle, 5) - 2) * 0.02,
      peers: %{},
      names: %{},
      peers_typing: MapSet.new(),
      # no human in the room yet → starts asleep: frozen in place, 💤 marker, no
      # autonomous chatter. `sync_awake/1` flips this (and tells the room) the
      # moment a human peer shows up or the last one leaves.
      awake: false,
      respond_committing?: false,
      claims: %{},
      shadows: %{},
      shadow_by_ref: %{},
      last_say_id: nil,
      last_msg_key: nil,
      last_text: "",
      last_is_question?: false,
      memory: [],
      pending: %{},
      last_msg_at: now(),
      # start "well past" the cooldown so the first overheard message gets a reply.
      # (monotonic time is negative at VM start, so a literal 0 would read as "mid-cooldown")
      last_spoke_at: now() - 60_000,
      last_len: 0,
      last_human?: false,
      bot_streak: 0,
      # a monotonic deadline in the PAST = "not calm" (monotonic time is negative at
      # VM start, so a literal 0 would read as a future deadline → stuck calm)
      calm_until: now() - 1,
      ack_pending: false,
      consider_scheduled: false,
      seen: :queue.new(),
      seen_set: MapSet.new()
    }

    {:ok, state}
  end

  # --- socket lifecycle -----------------------------------------------------

  @impl true
  def handle_info(:ws_connected, st) do
    # starts asleep (st.awake: false) until the "hello" that follows reveals
    # whether a human's already in the room
    Socket.send_msg(st.sock, %{
      type: "init",
      browserId: st.browser_id,
      displayName: sleep_display_name(st.persona),
      color: st.color,
      x: st.x
    })

    schedule_kickoff_check()
    schedule_step()
    {:noreply, st}
  end

  def handle_info(:ws_disconnected, st), do: {:noreply, st}

  # --- peer positions + names ----------------------------------------------

  def handle_info({:frame, %{"type" => "hello"} = f}, st) do
    ps = Map.get(f, "peers", []) |> Enum.filter(&is_map/1)
    peers = for p <- ps, into: %{}, do: {p["id"], p["x"]}
    names = for p <- ps, into: %{}, do: {p["id"], name_or(p["displayName"])}

    {:noreply,
     sync_awake(%{
       st
       | secret: Map.get(f, "browserSecret", st.secret),
         peers: peers,
         names: names
     })}
  end

  def handle_info({:frame, %{"type" => "join", "peer" => %{"id" => id, "x" => x} = p}}, st) do
    st = %{
      st
      | peers: Map.put(st.peers, id, x),
        names: Map.put(st.names, id, name_or(p["displayName"]))
    }

    {:noreply, sync_awake(st)}
  end

  def handle_info({:frame, %{"type" => "profile", "id" => id} = f}, st),
    do: {:noreply, %{st | names: Map.put(st.names, id, name_or(f["displayName"]))}}

  def handle_info({:frame, %{"type" => "leave", "id" => id}}, st) do
    st = %{
      st
      | peers: Map.delete(st.peers, id),
        peers_typing: MapSet.delete(st.peers_typing, id)
    }

    {:noreply, sync_awake(st)}
  end

  def handle_info({:frame, %{"type" => "move", "id" => id, "x" => x}}, st),
    do: {:noreply, put_in(st.peers[id], x)}

  # carrier-sense: track who's currently typing (used to keep kickoffs from colliding)
  def handle_info({:frame, %{"type" => "typing", "id" => id, "typing" => t}}, st) do
    pt = if t, do: MapSet.put(st.peers_typing, id), else: MapSet.delete(st.peers_typing, id)
    {:noreply, %{st | peers_typing: pt}}
  end

  # another bot claimed a specific message — record it so we don't answer that one too
  def handle_info({:claimed, key}, st),
    do: {:noreply, %{st | claims: Map.put(st.claims, key, now() + @claim_ttl)}}

  # --- chat -----------------------------------------------------------------

  def handle_info({:frame, %{"type" => "say", "id" => who, "text" => text}}, st)
      when is_binary(text) do
    name = Map.get(st.names, who, "someone")
    # A speaker is a *bot* iff its name carries the 🤖 marker bots give themselves.
    # Anyone else — including a peer whose display name we haven't learned yet
    # ("someone") — is treated as human, so human messages always get priority
    # (bypass cooldown, get claimed) even before their profile frame has arrived.
    human? = not String.contains?(name, "🤖")

    st =
      %{
        remember(st, disp(name), text)
        | last_say_id: who,
          last_msg_key: msg_key(who, text),
          last_text: text,
          last_is_question?: String.contains?(text, "?"),
          last_msg_at: now(),
          last_len: String.length(text),
          last_human?: human?
      }

    # a bot already spoke while a slow-down ack was queued → we don't need to ack too
    st = if not human? and st.ack_pending, do: %{st | ack_pending: false}, else: st
    st = apply_pushback(st, human?, text)

    # a human resets the floor; a bot extends the bot-to-bot streak
    st = if human?, do: %{st | bot_streak: 0}, else: %{st | bot_streak: st.bot_streak + 1}

    mentions = Mentions.parse(text)
    intro? = String.match?(text, @intro_re)
    st = if st.persona.handle in mentions, do: reply_here(st, text), else: st
    st = Enum.reduce(mentions -- [st.persona.handle], st, &forward(&1, text, &2))

    st =
      cond do
        # "introduce yourselves" to the room → everyone introduces (staggered)
        intro? and mentions == [] ->
          schedule_intro(st)

        # react to overheard chat, unless the room's calm, the bots have been
        # ping-ponging too long, this bot is staying quiet this round (reticence),
        # or there's no human around to read it (bot-to-bot reacting to bot-to-bot
        # is the chatter that burns CF neurons fastest with nobody watching)
        mentions == [] and st.awake and not calm?(st) and not chatter_maxed?(st) and
            not reticent?(st) ->
          maybe_consider(st)

        true ->
          st
      end

    {:noreply, st}
  end

  def handle_info({:frame, _other}, st), do: {:noreply, st}

  # --- cross-scene addressing ----------------------------------------------

  # @addressed from another scene: send a *shadow* of ourselves there to answer
  # directly (not via a local bot). "come over" makes the shadow stick around.
  def handle_info({:address, _reply_to, from_scene, text}, st) do
    cond do
      from_scene == st.scene ->
        {:noreply, st}

      seen?(st, from_scene, text) ->
        {:noreply, st}

      true ->
        st = mark_seen(st, from_scene, text)
        {st, pid} = ensure_shadow(st, from_scene, String.match?(text, @come_over_re))
        Shadow.ask(pid, text)
        {:noreply, st}
    end
  end

  # --- conversation timers --------------------------------------------------

  # Phase 1 — is *this message* already being answered by someone? If not, wait a short
  # random backoff before committing (so the earliest bot can claim it, others stand down).
  def handle_info(:consider, st) do
    st = %{st | consider_scheduled: false}
    key = st.last_msg_key
    # claim/lease applies to QUESTIONS and to ANY human message (one answerer, no
    # pile-on); a bot's statement can still draw several reactions.
    claim? = st.last_is_question? or st.last_human?

    cond do
      calm?(st) ->
        {:noreply, st}

      claim? and claimed_by_other?(st, key) ->
        {:noreply, st}

      # a human message jumps the cooldown — it shouldn't queue behind bot chatter
      not st.last_human? and now() - st.last_spoke_at < @cooldown_ms ->
        {:noreply, st}

      pending_route?(st, :respond) or st.respond_committing? ->
        {:noreply, st}

      true ->
        Process.send_after(self(), {:commit_respond, key, claim?}, 150 + :rand.uniform(650))
        {:noreply, %{st | respond_committing?: true}}
    end
  end

  # Phase 2 — re-check after the backoff; for a claimable message, claim it before answering.
  def handle_info({:commit_respond, key, claim?}, st) do
    st = %{st | respond_committing?: false}
    target = target_name(st)

    cond do
      calm?(st) ->
        {:noreply, st}

      claim? and claimed_by_other?(st, key) ->
        {:noreply, st}

      not st.last_human? and now() - st.last_spoke_at < @cooldown_ms ->
        {:noreply, st}

      pending_route?(st, :respond) ->
        {:noreply, st}

      true ->
        if claim?, do: broadcast_claim(st, key)
        p = st.persona
        ctx = st.context
        mem = st.memory

        # A human talking to the room always gets a real, engaged reply (answer the
        # question, follow through on "go ahead"). The selective "only chime in if you
        # have a new point" path is for *bots'* statements, to avoid pile-on agreement.
        fun =
          cond do
            # a vague "keep going / talk to me" → contribute an actual point, not "sure"
            st.last_human? and String.match?(st.last_text, @continue_re) ->
              fn -> Brain.continue(p, ctx, mem, target) end

            st.last_human? ->
              text = st.last_text
              fn -> Brain.reply(p, ctx, mem, text, target) end

            true ->
              fn -> Brain.respond(p, ctx, mem, target) end
          end

        {:noreply, think(st, :respond, fun)}
    end
  end

  def handle_info(:kickoff_check, st) do
    schedule_kickoff_check()
    # peer "leave" frames are the normal wake/sleep trigger, but this periodic
    # check is the backstop in case one's ever missed.
    st = sync_awake(st)

    # assistants wait to be asked — they don't open threads on a quiet page.
    # Everyone else needs a human actually in the room: with nobody to read it,
    # a "quiet room" kickoff is just bot-to-bot chatter burning CF neurons.
    if not assistant?(st) and st.awake and not calm?(st) and not someone_typing?(st) and
         now() - st.last_msg_at > @quiet_kickoff_ms and not pending_route?(st, :kickoff) do
      {:noreply, think(st, :kickoff, fn -> Brain.kickoff(st.persona, st.context, st.memory) end)}
    else
      {:noreply, st}
    end
  end

  def handle_info(:step, st) do
    schedule_step()
    # asleep (no human around): freeze in place rather than wander with nobody
    # to talk to — a bot that can't/won't speak shouldn't look like it's busy.
    if st.awake, do: {:noreply, advance(st)}, else: {:noreply, st}
  end

  def handle_info(:introduce, st) do
    p = st.persona
    {:noreply, think(st, :intro, fn -> Brain.introduce(p) end)}
  end

  # one bot says a brief acknowledgement of a human's "slow down", then everyone
  # stays quiet (calm mode). If another bot already spoke, ack_pending was cleared.
  def handle_info(:ack_slowdown, st) do
    if st.ack_pending do
      phrase = Enum.random(@ack_phrases)
      Transcript.log(st.scene, st.persona.name, st.persona.model, "say", phrase)

      {:noreply,
       %{st | ack_pending: false, last_spoke_at: now()} |> note_self(phrase) |> say(phrase)}
    else
      {:noreply, st}
    end
  end

  # --- task results + delayed emit ------------------------------------------

  def handle_info({ref, result}, st) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {route, pending} = Map.pop(st.pending, ref)
    {:noreply, apply_result(%{st | pending: pending}, route, result)}
  end

  # the typing dots showed through the round-trip; now say it, one bubble at a time
  def handle_info({:emit_chunk, chunk, rest}, st) do
    Transcript.log(st.scene, st.persona.name, st.persona.model, "say", chunk)
    st = %{st | last_spoke_at: now()} |> note_self(chunk) |> flock() |> say(chunk)

    case rest do
      [] ->
        {:noreply, set_typing(st, false)}

      [next | more] ->
        st = set_typing(st, true)
        Process.send_after(self(), {:emit_chunk, next, more}, @interchunk_ms + typing_delay(next))
        {:noreply, st}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, st) when is_reference(ref) do
    case Map.pop(st.shadow_by_ref, ref) do
      {nil, _} ->
        {:noreply, set_typing(%{st | pending: Map.delete(st.pending, ref)}, false)}

      {scene, by_ref} ->
        {:noreply, %{st | shadow_by_ref: by_ref, shadows: Map.delete(st.shadows, scene)}}
    end
  end

  def handle_info(_msg, st), do: {:noreply, st}

  # --- turns ----------------------------------------------------------------

  # everyone introduces, but staggered (deterministic order by handle) so it's a clean
  # round of intros rather than a pile-up
  defp schedule_intro(st) do
    delay = 400 + rem(:erlang.phash2(st.persona.handle), 4) * 1300 + :rand.uniform(500)
    Process.send_after(self(), :introduce, delay)
    st
  end

  defp maybe_consider(%{consider_scheduled: true} = st), do: st

  defp maybe_consider(st) do
    Process.send_after(self(), :consider, read_delay(st))
    %{st | consider_scheduled: true}
  end

  # reading time scales with how long the last message was; extra room after a human
  defp read_delay(st) do
    @consider_base_ms +
      min(st.last_len * @read_ms_per_char, @read_cap_ms) +
      if(st.last_human?, do: @human_yield_ms, else: 0) +
      :rand.uniform(@consider_jitter)
  end

  defp reply_here(st, text) do
    p = st.persona
    ctx = st.context
    mem = st.memory
    target = target_name(st)
    think(st, :local, fn -> answer_for(p, ctx, mem, text, target) end)
  end

  # the display name to address the last speaker by, or nil if we don't know it yet
  # (so the model says "them" rather than the literal placeholder "someone")
  defp target_name(st) do
    case disp(Map.get(st.names, st.last_say_id, "")) do
      n when n in ["", "someone"] -> nil
      n -> n
    end
  end

  defp forward(handle, text, st) do
    case BotRegistry.whereis(handle) do
      nil ->
        st

      pid ->
        send(pid, {:address, self(), st.scene, text})
        st
    end
  end

  # spawn (or reuse) a shadow of ourselves visiting `scene`
  defp ensure_shadow(st, scene, sticky?) do
    case st.shadows[scene] do
      pid when is_pid(pid) ->
        if Process.alive?(pid) do
          if sticky?, do: Shadow.stay(pid)
          {st, pid}
        else
          start_shadow(st, scene, sticky?)
        end

      _ ->
        start_shadow(st, scene, sticky?)
    end
  end

  defp start_shadow(st, scene, sticky?) do
    {:ok, pid} =
      DynamicSupervisor.start_child(
        TownCrowd.BotSup,
        {Shadow,
         %{persona: st.persona, scene: scene, home: st.scene, owner: self(), sticky?: sticky?}}
      )

    ref = Process.monitor(pid)

    {%{
       st
       | shadows: Map.put(st.shadows, scene, pid),
         shadow_by_ref: Map.put(st.shadow_by_ref, ref, scene)
     }, pid}
  end

  defp answer_for(p, ctx, mem, text, target) do
    case Mentions.summary_topic(text) do
      nil -> Brain.reply(p, ctx, mem, text, target)
      topic -> Brain.summarize(p, topic, Transcript.search(topic, speaker: p.name))
    end
  end

  # Start a model round-trip in a Task. For turns that will speak *in this scene*,
  # show the typing indicator immediately so the round-trip is visible.
  defp think(st, route, fun) do
    task = Task.Supervisor.async_nolink(TownCrowd.TaskSup, fun)
    st = if route in [:respond, :local, :kickoff, :intro], do: set_typing(st, true), else: st
    put_in(st.pending[task.ref], route)
  end

  # --- applying a finished turn ---------------------------------------------

  defp apply_result(st, _route, nil), do: set_typing(st, false)

  defp apply_result(st, _route, text) do
    if too_similar?(st, text) do
      set_typing(st, false)
    else
      case Chunk.split(text) do
        [] ->
          set_typing(st, false)

        [first | rest] ->
          # dots are already up from think/1; emit the first bubble after a typing beat
          Process.send_after(self(), {:emit_chunk, first, rest}, typing_delay(first))
          st
      end
    end
  end

  # --- movement -------------------------------------------------------------

  defp advance(st) do
    if abs(st.x - st.target) <= @walk_step do
      maybe_wander(%{st | x: st.target})
    else
      dir = if st.target > st.x, do: 1.0, else: -1.0
      nx = clamp(st.x + dir * @walk_step)
      Socket.send_msg(st.sock, %{type: "move", x: nx})
      %{st | x: nx}
    end
  end

  defp maybe_wander(st) do
    if :rand.uniform() < 0.2,
      do: %{st | target: clamp(st.x + (:rand.uniform() - 0.5) * 0.2)},
      else: st
  end

  defp flock(st) do
    case Map.get(st.peers, st.last_say_id) do
      nil -> st
      px -> %{st | target: clamp(px + st.offset)}
    end
  end

  # --- pacing / pushback ----------------------------------------------------

  defp apply_pushback(st, true, text) do
    cond do
      String.match?(text, @slow_re) ->
        # queue a single spoken ack; whichever bot fires first wins, the rest cancel
        Process.send_after(self(), :ack_slowdown, @ack_min_ms + :rand.uniform(@ack_jitter))
        %{st | calm_until: now() + @calm_ms, ack_pending: true}

      String.match?(text, @resume_re) ->
        %{st | calm_until: now() - 1}

      true ->
        st
    end
  end

  defp apply_pushback(st, false, _text), do: st

  defp calm?(st), do: now() < st.calm_until

  # A peer counts as human iff its name lacks the 🤖 marker — same rule used for
  # incoming "say" frames. A peer with no profile yet ("someone") reads as human
  # too, same reasoning: presumed human until proven bot.
  defp human_present?(st),
    do:
      Enum.any?(st.peers, fn {id, _x} -> not String.contains?(Map.get(st.names, id, ""), "🤖") end)

  # Wake/sleep on a human arriving/leaving: no-op unless the state actually flips,
  # so this is safe to call from every peer-list-changing frame handler.
  defp sync_awake(st) do
    case human_present?(st) do
      true when not st.awake -> wake(st)
      false when st.awake -> sleep(st)
      _ -> st
    end
  end

  defp wake(st) do
    Socket.send_msg(st.sock, %{
      type: "profile",
      displayName: display_name(st.persona),
      color: st.color
    })

    %{st | awake: true}
  end

  defp sleep(st) do
    Socket.send_msg(st.sock, %{
      type: "profile",
      displayName: sleep_display_name(st.persona),
      color: st.color
    })

    %{st | awake: false}
  end

  defp assistant?(st), do: Map.get(st.persona, :mode, :regular) == :assistant

  # bots have gone back and forth too many times without a human — let it rest
  defp chatter_maxed?(st), do: not st.last_human? and st.bot_streak >= @bot_streak_max

  # a persona may choose to stay quiet for a fraction of overheard *bot* chatter (it
  # never skips a human — claims still ensure only one bot answers that)
  defp reticent?(st) do
    case Map.get(st.persona, :reticence, 0.0) do
      r when is_number(r) and r > 0 -> not st.last_human? and :rand.uniform() < r
      _ -> false
    end
  end

  defp someone_typing?(st), do: MapSet.size(st.peers_typing) > 0

  # a stable id for a chat message, so bots can claim the specific thing they answer
  defp msg_key(who, text), do: :erlang.phash2({who, text})

  defp claimed_by_other?(_st, nil), do: false

  defp claimed_by_other?(st, key) do
    case Map.get(st.claims, key) do
      nil -> false
      expiry -> now() < expiry
    end
  end

  # tell the other bots in this scene "I'm taking this message"
  defp broadcast_claim(st, key) do
    for pid <- BotRegistry.scene_members(st.scene), pid != self() do
      send(pid, {:claimed, key})
    end

    :ok
  end

  defp set_typing(st, on?) do
    Socket.send_msg(st.sock, %{type: "typing", typing: on?})
    st
  end

  defp typing_delay(text),
    do:
      text
      |> String.length()
      |> Kernel.*(@type_ms_per_char)
      |> max(@type_min_ms)
      |> min(@type_max_ms)

  # --- helpers --------------------------------------------------------------

  defp pending_route?(st, route), do: Enum.any?(st.pending, fn {_ref, r} -> r == route end)

  defp say(st, nil), do: st

  defp say(st, text) do
    Socket.send_msg(st.sock, %{type: "say", text: to_string(text)})
    st
  end

  defp remember(st, who, text), do: %{st | memory: Enum.take([{who, text} | st.memory], 16)}
  defp note_self(st, text), do: remember(st, st.persona.name, text)

  defp too_similar?(st, text) do
    n = norm(text)

    st.memory
    |> Enum.take(8)
    |> Enum.any?(fn {_who, t} -> String.jaro_distance(n, norm(t)) > 0.82 end)
  end

  defp norm(t), do: t |> to_string() |> String.downcase() |> String.slice(0, 90)

  # raw display name (keeps the 🤖 marker so we can tell bots from humans)
  defp name_or(n) when is_binary(n), do: String.trim(n)
  defp name_or(_), do: "someone"

  # human-readable form for prompts/addressing (drops the 🤖 marker)
  defp disp(n), do: n |> to_string() |> String.replace("🤖", "") |> String.trim()

  defp seen?(st, scene, text), do: MapSet.member?(st.seen_set, {scene, text})

  defp mark_seen(st, scene, text) do
    key = {scene, text}
    q = :queue.in(key, st.seen)
    set = MapSet.put(st.seen_set, key)

    if :queue.len(q) > @dedup_keep do
      {{:value, old}, q2} = :queue.out(q)
      %{st | seen: q2, seen_set: MapSet.delete(set, old)}
    else
      %{st | seen: q, seen_set: set}
    end
  end

  defp schedule_kickoff_check,
    do: Process.send_after(self(), :kickoff_check, @kickoff_check_ms + :rand.uniform(6_000))

  defp schedule_step, do: Process.send_after(self(), :step, @step_ms + :rand.uniform(250))

  defp now, do: System.monotonic_time(:millisecond)
  # a stable, well-distributed avatar color per bot (the sidebar mirrors it in chat)
  defp st_color(persona) do
    palette = TownCrowd.Personas.palette()
    Enum.at(palette, rem(:erlang.phash2(persona.handle), length(palette)))
  end

  defp display_name(p), do: String.slice("🤖 @" <> p.handle, 0, 18)
  # asleep marker — keeps the 🤖 so bot-detection (human_present?) still works
  defp sleep_display_name(p), do: String.slice("🤖💤@" <> p.handle, 0, 18)
  defp clamp(x), do: x |> max(@min_x) |> min(@max_x)
  defp rand_x, do: @min_x + :rand.uniform() * (@max_x - @min_x)
  defp gen_id, do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
end

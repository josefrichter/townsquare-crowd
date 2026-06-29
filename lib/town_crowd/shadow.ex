defmodule TownCrowd.Shadow do
  @moduledoc """
  A bot's visiting presence in a scene that isn't its home.

  When you address a bot that lives elsewhere, its home process spawns one of these:
  the bot's *own* avatar appears in your scene (tagged with where it's from), answers
  you directly — not ventriloquized through another bot — and leaves after a quiet
  spell. If you tell it to "come over", it stays (sticky).
  """

  use GenServer
  require Logger

  alias TownCrowd.{Socket, Brain, Context, Transcript, Chunk}

  @ttl 60_000
  @ttl_check 15_000
  @type_per 45
  @type_min 600
  @type_max 3_000
  @interchunk 1_200

  def start_link(args), do: GenServer.start_link(__MODULE__, args)

  def ask(pid, text), do: send(pid, {:ask, text})
  def stay(pid), do: send(pid, :stay)

  @impl true
  def init(%{persona: p, scene: scene, home: home, owner: owner} = a) do
    {:ok, sock} = Socket.start_link(%{owner: self(), url: TownCrowd.ws_url(scene)})

    {:ok,
     %{
       persona: p,
       scene: scene,
       home: home,
       owner: owner,
       sock: sock,
       context: Context.article(scene),
       sticky?: Map.get(a, :sticky?, false),
       announced?: false,
       joined?: false,
       queue: [],
       last_ask_at: now()
     }}
  end

  @impl true
  def handle_info(:ws_connected, st) do
    Socket.send_msg(st.sock, %{
      type: "init",
      browserId: gen(),
      displayName: vis_name(st),
      color: st.persona.color,
      x: 0.5
    })

    schedule_ttl()
    st = %{st | joined?: true}
    {:noreply, Enum.reduce(Enum.reverse(st.queue), %{st | queue: []}, &answer(&2, &1))}
  end

  def handle_info(:ws_disconnected, st), do: {:noreply, st}
  def handle_info(:stay, st), do: {:noreply, %{st | sticky?: true}}

  def handle_info({:ask, text}, st) do
    st = %{st | last_ask_at: now()}
    if st.joined?, do: {:noreply, answer(st, text)}, else: {:noreply, %{st | queue: [text | st.queue]}}
  end

  def handle_info({ref, result}, st) when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    case result do
      nil ->
        {:noreply, set_typing(st, false)}

      text ->
        # while visiting, mark the first reply with the full origin; once it's "come
        # over" (sticky) or has already announced, drop the tag — it's a local now.
        {text, st} =
          if st.sticky? or st.announced? do
            {text, st}
          else
            {"[from #{st.home}] " <> text, %{st | announced?: true}}
          end

        case Chunk.split(text) do
          [] -> {:noreply, set_typing(st, false)}
          [first | rest] -> Process.send_after(self(), {:emit, first, rest}, tdelay(first)); {:noreply, st}
        end
    end
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, st), do: {:noreply, st}

  def handle_info({:emit, chunk, rest}, st) do
    Transcript.log(st.scene, vis_name(st), st.persona.model, "say", chunk)
    Socket.send_msg(st.sock, %{type: "say", text: chunk})

    case rest do
      [] ->
        {:noreply, set_typing(st, false)}

      [next | more] ->
        st = set_typing(st, true)
        Process.send_after(self(), {:emit, next, more}, @interchunk + tdelay(next))
        {:noreply, st}
    end
  end

  def handle_info(:ttl, st) do
    if not st.sticky? and now() - st.last_ask_at > @ttl do
      {:stop, :normal, st}
    else
      schedule_ttl()
      {:noreply, st}
    end
  end

  def handle_info(_msg, st), do: {:noreply, st}

  # --- internals ------------------------------------------------------------

  defp answer(st, text) do
    st = set_typing(st, true)
    p = st.persona
    ctx = st.context
    Task.Supervisor.async_nolink(TownCrowd.TaskSup, fn -> Brain.reply(p, ctx, [], text, "them") end)
    st
  end

  defp set_typing(st, on?) do
    Socket.send_msg(st.sock, %{type: "typing", typing: on?})
    st
  end

  defp tdelay(t), do: t |> String.length() |> Kernel.*(@type_per) |> max(@type_min) |> min(@type_max)
  defp vis_name(st), do: String.slice("🤖 @#{st.persona.handle}", 0, 18)
  defp now, do: System.monotonic_time(:millisecond)
  defp schedule_ttl, do: Process.send_after(self(), :ttl, @ttl_check)
  defp gen, do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
end

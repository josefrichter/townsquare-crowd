defmodule TownCrowd.Application do
  @moduledoc """
  The supervision tree. Bots are started on demand under a DynamicSupervisor, each
  isolated: a bot that crashes (a bad LLM reply, a socket fault) is restarted on its
  own and takes nothing else with it.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Cluster-wide bot directory (handle -> pid). Starts :pg; works across nodes
      # the moment they're connected, with no change to anything below.
      TownCrowd.BotRegistry,

      # Persistence: every line the bots say, appended to a log + held for search.
      TownCrowd.Transcript,

      # LLM round-trips run here as tasks, so a bot never blocks its mailbox while
      # waiting for the model — it stays responsive to mentions mid-thought.
      {Task.Supervisor, name: TownCrowd.TaskSup},

      # One process per bot, supervised and isolated.
      {DynamicSupervisor, name: TownCrowd.BotSup, strategy: :one_for_one},

      # Reads the persona list and spawns the population.
      TownCrowd.Population
    ]

    case Supervisor.start_link(children, strategy: :one_for_one, name: TownCrowd.Supervisor) do
      {:ok, pid} ->
        banner()
        {:ok, pid}

      other ->
        other
    end
  end

  defp banner do
    ws = Application.get_env(:town_crowd, :townsquare_ws, "ws://127.0.0.1:8788")
    personas = TownCrowd.Personas.all()

    IO.puts("")
    IO.puts("  town_crowd — #{length(personas)} bots ready, connecting to #{ws}")
    IO.puts("  backend: #{TownCrowd.Personas.backend()}  (set CROWD_BACKEND=cf for Cloudflare Workers AI)")

    personas
    |> Enum.group_by(& &1.site_key)
    |> Enum.each(fn {scene, bots} ->
      IO.puts("  · scene #{scene}/")
      Enum.each(bots, fn b -> IO.puts("      🤖 #{b.name}  @#{b.handle}  [#{b.model}]") end)
    end)

    brains =
      [
        {"ollama", "OLLAMA_HOST", true},
        {"cloudflare", "CF_API_TOKEN", false},
        {"anthropic", "ANTHROPIC_API_KEY", false}
      ]
      |> Enum.filter(fn {_n, var, always} -> always or System.get_env(var) not in [nil, ""] end)
      |> Enum.map_join(", ", &elem(&1, 0))

    IO.puts("  brains: #{brains}   history: crowd_transcript.jsonl")
    IO.puts("")
  end
end

defmodule TownCrowd.Population do
  @moduledoc """
  Spawns each configured persona exactly once, cluster-wide.

  Fly runs this app on two machines (for zero-downtime deploys), and libcluster
  connects them into one distributed-Erlang cluster (see config/runtime.exs), so
  BotRegistry's `:pg` directory is genuinely cluster-wide. On a recurring
  reconcile pass, a persona missing everywhere gets spawned locally; one that's
  already running (here or on the other machine) is left alone.

  A boot-time race is still possible — both machines can come up before the
  cluster has connected and both decide a persona is missing — so reconcile also
  reaps duplicates: if a handle ends up with more than one pid cluster-wide,
  every node applies the same deterministic tie-break (sort by `{node, pid}`,
  keep the first) and kills only the local losers, no coordination required.
  """

  use GenServer
  require Logger

  alias TownCrowd.BotRegistry

  # gives libcluster's DNSPoll (2s interval) a head start before the first
  # reconcile, so a cold two-machine boot is less likely to double-spawn
  @initial_delay_ms 5_000
  @reconcile_ms 15_000

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Start one extra bot from a persona map at runtime."
  def spawn_bot(persona),
    do: DynamicSupervisor.start_child(TownCrowd.BotSup, {TownCrowd.Bot, persona})

  @impl true
  def init(_) do
    Process.send_after(self(), :reconcile, @initial_delay_ms)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:reconcile, st) do
    Process.send_after(self(), :reconcile, @reconcile_ms)
    Enum.each(TownCrowd.Personas.all(), &reconcile_one/1)
    {:noreply, st}
  end

  defp reconcile_one(persona) do
    case BotRegistry.whereis_all(persona.handle) do
      [] -> spawn_bot(persona)
      [_one] -> :ok
      dupes -> reap_duplicates(persona.handle, dupes)
    end
  end

  defp reap_duplicates(handle, pids) do
    [keep | losers] = Enum.sort_by(pids, &{node(&1), &1})

    Logger.warning(
      "Population: #{length(pids)} copies of @#{handle} found, keeping #{inspect(keep)}"
    )

    for pid <- losers, node(pid) == node() do
      DynamicSupervisor.terminate_child(TownCrowd.BotSup, pid)
    end
  end
end

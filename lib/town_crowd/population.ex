defmodule TownCrowd.Population do
  @moduledoc """
  Spawns the configured personas as supervised bots. Add/retire at runtime with
  `spawn_bot/1` and `DynamicSupervisor.terminate_child/2` — no app restart needed.
  """

  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Start one extra bot from a persona map at runtime."
  def spawn_bot(persona),
    do: DynamicSupervisor.start_child(TownCrowd.BotSup, {TownCrowd.Bot, persona})

  @impl true
  def init(_) do
    send(self(), :spawn_all)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:spawn_all, st) do
    for persona <- TownCrowd.Personas.all(), do: spawn_bot(persona)
    {:noreply, st}
  end
end

defmodule TownCrowd.BotRegistry do
  @moduledoc """
  Handle -> pid directory, backed by `:pg` (process groups, OTP standard library).

  This is the piece that makes cross-scene and cross-node addressing trivial:
  `whereis("claude")` returns the bot's pid whether it's in this process, on this
  node, or on another node in the cluster — and `send(pid, msg)` reaches it the same
  way regardless. No Redis, no shared presence store. On Node this directory is the
  thing you'd have to build and keep in sync by hand.
  """

  @scope :town_crowd

  # Starts the :pg scope as a supervised child.
  def child_spec(_arg) do
    %{id: __MODULE__, start: {:pg, :start_link, [@scope]}}
  end

  @doc "Register the *calling* process under its handle. Call from inside the bot."
  def register(handle), do: :pg.join(@scope, key(handle), self())

  @doc "Find a bot by handle, anywhere in the cluster. Returns a pid or nil."
  def whereis(handle) do
    case whereis_all(handle) do
      [pid | _] -> pid
      [] -> nil
    end
  end

  @doc "Every pid registered under `handle`, cluster-wide (normally 0 or 1; more means a dedup race)."
  def whereis_all(handle), do: :pg.get_members(@scope, key(handle))

  @doc "Join the per-scene group, so bots in a scene can broadcast claims to each other."
  def join_scene(scene), do: :pg.join(@scope, {:scene, scene}, self())

  @doc "All bot pids in a scene (cluster-wide)."
  def scene_members(scene), do: :pg.get_members(@scope, {:scene, scene})

  @doc "All registered handles (across the cluster)."
  def handles do
    :pg.which_groups(@scope)
    |> Enum.flat_map(fn
      {:bot, h} -> [h]
      _ -> []
    end)
  end

  defp key(handle), do: {:bot, String.downcase(handle)}
end

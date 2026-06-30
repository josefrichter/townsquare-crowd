defmodule TownCrowd.Status do
  @moduledoc """
  The only HTTP surface this app has — it's an outbound WS client, not a server.
  Exists so Fly has a real `/healthz` to poll and so `crowd.josefrichter.design`
  shows something useful instead of nothing: which bots are configured, whether
  each is currently connected to its scene, and the last few lines they've said.
  """

  use Plug.Router

  plug(:match)
  plug(:dispatch)

  get "/healthz" do
    send_resp(conn, 200, "ok")
  end

  get "/" do
    send_resp(conn, 200, page())
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  defp page do
    personas = TownCrowd.Personas.all()
    backend = TownCrowd.Personas.backend()
    online = MapSet.new(TownCrowd.BotRegistry.handles())

    rows =
      personas
      |> Enum.group_by(& &1.site_key)
      |> Enum.map_join("\n", fn {scene, bots} ->
        bot_lines =
          Enum.map_join(bots, "\n", fn b ->
            state = if MapSet.member?(online, b.handle), do: "online", else: "offline"
            "    @#{b.handle}  #{state}  [#{b.model}]"
          end)

        "  #{scene}/\n#{bot_lines}"
      end)

    recent =
      TownCrowd.Transcript.search("")
      |> Enum.sort_by(& &1.seq, :desc)
      |> Enum.take(10)
      |> Enum.reverse()
      |> Enum.map_join("\n", &"  [#{&1.scene}] #{&1.speaker}: #{&1.text}")

    """
    town_crowd — backend: #{backend}

    bots:
    #{rows}

    last activity:
    #{if recent == "", do: "  (none yet)", else: recent}
    """
  end
end

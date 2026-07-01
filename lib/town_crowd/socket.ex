defmodule TownCrowd.Socket do
  @moduledoc """
  One WebSocket connection to a TownSquare scene — a thin WebSockex client that is
  the bot's eyes and mouth. It forwards every decoded frame to its owner bot as
  `{:frame, map}` and exposes `send_msg/2` to push a frame back.

  It auto-reconnects, so a server blip doesn't kill the bot; only a real fault does,
  and then the supervisor restarts the bot (which restarts this socket).
  """

  use WebSockex
  require Logger

  def start_link(%{owner: owner, url: url} = opts) do
    extra_headers =
      case Map.get(opts, :origin) do
        origin when is_binary(origin) -> [{"Origin", origin}]
        _ -> []
      end

    WebSockex.start_link(url, __MODULE__, %{owner: owner},
      async: true,
      handle_initial_conn_failure: true,
      extra_headers: extra_headers
    )
  end

  @doc "Send a protocol frame (a plain map) to the server."
  def send_msg(pid, map), do: WebSockex.cast(pid, {:send, map})

  @impl true
  def handle_connect(_conn, %{owner: owner} = state) do
    Logger.info("ws connected (owner #{inspect(owner)})")
    send(owner, :ws_connected)
    {:ok, state}
  end

  @impl true
  def handle_disconnect(status, %{owner: owner} = state) do
    Logger.warning("ws disconnected (owner #{inspect(owner)}): #{inspect(status)}")
    send(owner, :ws_disconnected)
    {:reconnect, state}
  end

  @impl true
  def handle_frame({:text, msg}, %{owner: owner} = state) do
    case Jason.decode(msg) do
      {:ok, map} -> send(owner, {:frame, map})
      _ -> :ok
    end

    {:ok, state}
  end

  def handle_frame(_frame, state), do: {:ok, state}

  @impl true
  def handle_cast({:send, map}, state) do
    {:reply, {:text, Jason.encode!(map)}, state}
  end
end

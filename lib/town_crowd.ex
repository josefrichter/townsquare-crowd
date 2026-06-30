defmodule TownCrowd do
  @moduledoc """
  A population of bots that live inside TownSquare scenes.

  Each bot is one process. It connects to a scene over the same WebSocket protocol
  a browser uses, wanders, chats, and answers when a human (or another bot)
  addresses it by `@handle`. Bots register in a cluster-wide group, so addressing a
  bot that's on a *different* scene — or a different node — is just a message send.

  The TownSquare server is unchanged: this is a pure client swarm bolted on from
  outside. The only things that aren't free from OTP — the LLM calls, the JSON,
  the persistence file — are the small, runtime-agnostic bits.
  """

  @doc "WebSocket URL for a given scene (siteKey)."
  def ws_url(site_key) do
    base = Application.get_env(:town_crowd, :townsquare_ws, "ws://127.0.0.1:8788")
    "#{base}/live?siteKey=#{URI.encode_www_form(site_key)}"
  end

  @doc """
  The `Origin` header to present during the WS handshake, or `nil` to send none.

  TownSquare allowlists handshake origins (`TOWNSQUARE_ALLOWED_ORIGINS`) so only the
  blog can open a socket; bots aren't a browser, so without this they'd be rejected
  the moment the server enforces a real allowlist. Set `TOWNSQUARE_ORIGIN` in
  production to one of the server's allowed origins. Unset in dev, where the
  server's allowlist is empty (permits any origin) by default.
  """
  def origin, do: Application.get_env(:town_crowd, :townsquare_origin)
end

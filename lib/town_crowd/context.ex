defmodule TownCrowd.Context do
  @moduledoc """
  Loads the article a scene is sitting under, as plain text, so the bots discuss
  *that* instead of making small talk.

  A scene's source is configured in `:articles` (a live URL — the production default)
  and may be shadowed by a local file in `:article_files` for development:

      config :town_crowd,
        articles:      %{"sorted.plus" => "https://sorted.plus/crowd"},
        article_files: %{"sorted.plus" => "../crowd-article.html"}  # wins if it exists

  The raw page is fetched/read once and memoized (per source), so both `article/1`
  and `links/1` come from a single load and repeat calls are free.
  """

  require Logger

  @max 9000
  @timeout 20_000

  @doc "Plain-text article for a scene, or nil if none configured/readable."
  def article(scene) do
    case raw_html(scene) do
      nil -> nil
      html -> html |> strip() |> String.slice(0, @max)
    end
  end

  @doc """
  External links in a scene's article as `[{anchor_text, url}]` — the things a
  tool-capable bot may `read_url` for more detail (the other article, references).
  Only http(s) links, deduped, capped.
  """
  def links(scene) do
    case raw_html(scene) do
      nil -> []
      html -> parse_links(html)
    end
  end

  # --- source resolution + memoized load ------------------------------------

  # local file wins when it exists (dev); otherwise the configured URL (production)
  defp source(scene) do
    file = Application.get_env(:town_crowd, :article_files, %{})[scene]

    cond do
      is_binary(file) and File.exists?(file) -> file
      true -> Application.get_env(:town_crowd, :articles, %{})[scene]
    end
  end

  defp raw_html(scene) do
    case source(scene) do
      nil -> nil
      src -> cached(src)
    end
  end

  # memoize the raw page by source string; never cache a failure (so a transient
  # fetch error or a not-yet-running dev server is retried next time)
  defp cached(src) do
    key = {__MODULE__, :raw, src}

    case :persistent_term.get(key, :miss) do
      :miss ->
        case load(src) do
          nil -> nil
          html -> :persistent_term.put(key, html); html
        end

      html ->
        html
    end
  end

  defp load("http" <> _ = url) do
    case Req.get(url, receive_timeout: @timeout, retry: false, redirect: true) do
      {:ok, %{status: s, body: body}} when s in 200..299 and is_binary(body) -> body
      {:ok, %{status: s}} -> Logger.warning("article fetch #{url} HTTP #{s}"); nil
      {:error, e} -> Logger.warning("article fetch #{url}: #{inspect(e)}"); nil
    end
  rescue
    e -> Logger.warning("article fetch crash #{url}: #{inspect(e)}"); nil
  end

  defp load(path) do
    case File.read(path) do
      {:ok, raw} -> raw
      _ -> nil
    end
  end

  # --- parsing --------------------------------------------------------------

  defp parse_links(raw) do
    Regex.scan(~r/<a\b[^>]*\bhref="(https?:\/\/[^"]+)"[^>]*>(.*?)<\/a>/si, raw)
    |> Enum.map(fn [_, url, text] -> {text |> strip() |> String.slice(0, 80), url} end)
    |> Enum.reject(fn {text, _} -> text == "" end)
    |> Enum.uniq_by(fn {_, url} -> url end)
    |> Enum.take(15)
  end

  # Crude HTML/markdown -> text. Good enough as LLM grounding.
  defp strip(raw) do
    raw
    |> String.replace(~r/<script.*?<\/script>/s, " ")
    |> String.replace(~r/<style.*?<\/style>/s, " ")
    |> String.replace(~r/<[^>]+>/, " ")
    |> String.replace("&mdash;", "—")
    |> String.replace("&rsquo;", "’")
    |> String.replace("&ldquo;", "“")
    |> String.replace("&rdquo;", "”")
    |> String.replace("&amp;", "&")
    |> String.replace(~r/&[a-z]+;/, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end
end

defmodule TownCrowd.Web do
  @moduledoc """
  The bots' window onto the web — two capabilities exposed to tool-capable models:

    * `read/1`  — fetch and read a page (e.g. a link from the article, or a search hit)
    * `search/1` — a keyword web search, for things the article doesn't cover

  Reading is the important one for this demo: the two articles link to each other, so
  when a human in one scene asks about the *other* topic, a bot can pull up that article
  and answer from it. Links whose host matches a configured scene (a known article
  domain) are short-circuited to the **local file**, so cross-article reading works
  offline; everything else goes out to the live web.

  Backed by the `web` CLI (renders pages to clean markdown) with a `Req` fallback, and
  Tavily for search when `TAVILY_API_KEY` is set (otherwise a keyless DuckDuckGo lite
  query). Every call returns a plain string — never raises — so a bot's tool call always
  gets *something* back rather than crashing its turn.
  """

  require Logger

  @cap 4_000
  @timeout 20_000

  @doc "Read a URL as text. Known article domains resolve to the local file."
  def read(url) when is_binary(url) do
    url = String.trim(url)

    cond do
      url == "" -> "no url given"
      scene = local_scene(url) -> local_article(scene)
      true -> fetch(url)
    end
  end

  def read(_), do: "no url given"

  @doc "Keyword web search; returns the top results as text."
  def search(query) when is_binary(query) do
    q = String.trim(query)
    if q == "", do: "no query given", else: do_search(q)
  end

  def search(_), do: "no query given"

  # --- read backends --------------------------------------------------------

  # if a link points at one of our own article domains, read the local file instead
  # of going to the network (works in the local demo, and is faster live too).
  defp local_scene(url) do
    host = uri_host(url)

    Application.get_env(:town_crowd, :articles, %{})
    |> Map.keys()
    |> Enum.find(fn scene -> host != nil and String.contains?(host, scene) end)
  end

  defp local_article(scene) do
    case TownCrowd.Context.article(scene) do
      nil -> "couldn't read the linked article"
      text -> cap("(#{scene})\n" <> text)
    end
  end

  defp fetch(url) do
    case web_cli(url) do
      {:ok, text} -> cap(text)
      :error -> req_get(url)
    end
  end

  # the `web` CLI renders to markdown and shares the user's browsing session
  defp web_cli(url) do
    case System.cmd("web", [url], stderr_to_stdout: true) do
      {out, 0} when byte_size(out) > 0 -> {:ok, out}
      _ -> :error
    end
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  defp req_get(url) do
    case Req.get(url, receive_timeout: @timeout, retry: false, redirect: true) do
      {:ok, %{status: s, body: body}} when s in 200..299 -> body |> to_text() |> cap()
      {:ok, %{status: s}} -> "page returned HTTP #{s}"
      {:error, e} -> "couldn't fetch the page (#{inspect(e)})"
    end
  rescue
    e -> "couldn't fetch the page (#{inspect(e)})"
  end

  # --- search backends ------------------------------------------------------

  defp do_search(query) do
    case System.get_env("TAVILY_API_KEY") do
      key when is_binary(key) and key != "" -> tavily(query, key)
      _ -> duckduckgo(query)
    end
  end

  defp tavily(query, key) do
    body = %{api_key: key, query: query, max_results: 5, include_answer: true}

    case Req.post("https://api.tavily.com/search", json: body, receive_timeout: @timeout, retry: false) do
      {:ok, %{status: 200, body: %{"results" => results} = b}} ->
        answer = b["answer"]
        lines = Enum.map_join(results, "\n", fn r -> "- #{r["title"]} (#{r["url"]}): #{r["content"]}" end)
        cap([answer, lines] |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join("\n\n"))

      {:ok, %{status: s}} ->
        "search returned HTTP #{s}"

      {:error, e} ->
        "search failed (#{inspect(e)})"
    end
  rescue
    e -> "search failed (#{inspect(e)})"
  end

  # keyless fallback: DuckDuckGo's lite HTML endpoint via the web CLI
  defp duckduckgo(query) do
    url = "https://lite.duckduckgo.com/lite/?q=" <> URI.encode_www_form(query)

    case web_cli(url) do
      {:ok, text} -> cap(text)
      :error -> req_get(url)
    end
  end

  # --- helpers --------------------------------------------------------------

  defp uri_host(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) -> host
      _ -> nil
    end
  end

  # crude HTML/body -> text (mirrors Context.strip for the Req fallback path)
  defp to_text(body) when is_binary(body) do
    body
    |> String.replace(~r/<script.*?<\/script>/s, " ")
    |> String.replace(~r/<style.*?<\/style>/s, " ")
    |> String.replace(~r/<[^>]+>/, " ")
    |> String.replace(~r/&[a-z]+;/, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp to_text(body), do: inspect(body)

  defp cap(text) do
    t = to_string(text) |> String.trim()
    if String.length(t) <= @cap, do: t, else: String.slice(t, 0, @cap) <> " …(truncated)"
  end
end

defmodule TownCrowd.Knowledge do
  @moduledoc """
  Scoped, read-only access to a local corpus — typically the full repo — that an
  assistant bot can search and read on demand. The corpus is too big to stuff into
  the prompt, so instead of dumping it we hand the bot two tools (`search_repo`,
  `read_file`) and let it pull just the slices it needs.

  Everything is sandboxed to a `root` directory configured per persona (`:knowledge`):
  paths that escape the root are refused, common junk dirs are skipped, and binary or
  oversized files are not returned. All calls return a plain string and never raise.
  """

  require Logger

  @cap 4_000
  @max_file_bytes 200_000
  @ignore ~w(.git _build deps node_modules .elixir_ls cover .git)

  @doc "Search the corpus for a term; returns matching `path:line: text`, capped."
  def search(nil, _query), do: "no knowledge base is configured for this bot"

  def search(root, query) when is_binary(query) do
    q = String.trim(query)

    cond do
      not File.dir?(root) -> "knowledge base not found"
      q == "" -> "no query given"
      true -> grep(root, q)
    end
  end

  def search(_root, _query), do: "no query given"

  @doc "Read one file from the corpus by its path relative to the root."
  def read(nil, _path), do: "no knowledge base is configured for this bot"

  def read(root, relpath) when is_binary(relpath) do
    case safe_path(root, relpath) do
      {:ok, abs} -> read_file(abs, root)
      :error -> "that path is outside the knowledge base"
    end
  end

  def read(_root, _path), do: "no path given"

  # --- search ---------------------------------------------------------------

  defp grep(root, q) do
    {cmd, args} = grep_cmd(root, q)

    case System.cmd(cmd, args, stderr_to_stdout: true) do
      # rg/grep exit 1 == "no matches" (not an error)
      {out, code} when code in [0, 1] ->
        out = out |> String.replace(Path.expand(root) <> "/", "") |> String.trim()
        if out == "", do: "no matches for \"#{q}\"", else: cap(out)

      _ ->
        "search unavailable"
    end
  rescue
    e -> Logger.warning("knowledge search: #{inspect(e)}"); "search failed"
  catch
    _, _ -> "search failed"
  end

  # prefer ripgrep (fast, respects ignores); fall back to grep
  defp grep_cmd(root, q) do
    if exe = System.find_executable("rg") do
      globs = Enum.flat_map(@ignore, fn d -> ["--glob", "!#{d}/**"] end)
      {exe, ["--line-number", "--no-heading", "--color=never", "-S", "--max-count=5", "--max-columns=200"] ++ globs ++ ["--", q, Path.expand(root)]}
    else
      excludes = Enum.map(@ignore, fn d -> "--exclude-dir=#{d}" end)
      {"grep", ["-rIns", "--max-count=5"] ++ excludes ++ ["--", q, Path.expand(root)]}
    end
  end

  # --- read -----------------------------------------------------------------

  # resolve `relpath` under `root`, refusing anything that escapes the sandbox
  defp safe_path(root, relpath) do
    base = Path.expand(root)
    abs = Path.expand(relpath, base)
    if abs == base or String.starts_with?(abs, base <> "/"), do: {:ok, abs}, else: :error
  end

  defp read_file(abs, root) do
    cond do
      not File.regular?(abs) ->
        "not a file: #{rel(abs, root)}"

      File.stat!(abs).size > @max_file_bytes ->
        "file too large to read: #{rel(abs, root)}"

      true ->
        case File.read(abs) do
          {:ok, bin} -> if binary?(bin), do: "binary file, skipped", else: cap("(#{rel(abs, root)})\n" <> bin)
          _ -> "could not read #{rel(abs, root)}"
        end
    end
  rescue
    e -> Logger.warning("knowledge read: #{inspect(e)}"); "could not read file"
  end

  # --- helpers --------------------------------------------------------------

  defp rel(abs, root), do: String.replace_prefix(abs, Path.expand(root) <> "/", "")
  defp binary?(bin), do: String.contains?(bin, <<0>>)

  defp cap(text) do
    t = String.trim(text)
    if String.length(t) <= @cap, do: t, else: String.slice(t, 0, @cap) <> " …(truncated)"
  end
end

defmodule TownCrowd.Chunk do
  @moduledoc """
  Split a reply into <=140-char bubbles, **breaking on sentence boundaries** (so a
  bubble is one or more whole sentences, never a mid-sentence cut). A single sentence
  longer than the cap is word-split as a fallback.

  This keeps the 140-char TownSquare protocol cap without raising it, and lets a
  longer thought arrive as a few clean bubbles.
  """

  @max 140

  def split(text) do
    text
    |> String.trim()
    |> sentences()
    |> pack()
  end

  # split into sentences, keeping their terminators
  defp sentences(text) do
    ~r/.*?[.!?]+(?:\s|$)|.+$/u
    |> Regex.scan(text)
    |> Enum.map(fn [s] -> String.trim(s) end)
    |> Enum.reject(&(&1 == ""))
  end

  # greedily pack whole sentences into <=@max bubbles
  defp pack(sentences) do
    {acc, cur} =
      Enum.reduce(sentences, {[], ""}, fn s, {acc, cur} ->
        cond do
          # a single sentence longer than the cap: flush, then word-split it
          String.length(s) > @max ->
            {(if cur == "", do: acc, else: acc ++ [cur]) ++ word_split(s), ""}

          cur == "" ->
            {acc, s}

          String.length(cur <> " " <> s) <= @max ->
            {acc, cur <> " " <> s}

          true ->
            {acc ++ [cur], s}
        end
      end)

    if cur == "", do: acc, else: acc ++ [cur]
  end

  # fallback for an over-long sentence: pack words to <=@max
  defp word_split(s) do
    {acc, cur} =
      s
      |> String.split(~r/\s+/, trim: true)
      |> Enum.reduce({[], ""}, fn w, {acc, cur} ->
        cand = if cur == "", do: w, else: cur <> " " <> w

        cond do
          String.length(cand) <= @max -> {acc, cand}
          cur == "" -> {acc ++ hard(w), ""}
          true -> {acc ++ [cur], w}
        end
      end)

    if cur == "", do: acc, else: acc ++ [cur]
  end

  defp hard(w), do: w |> String.codepoints() |> Enum.chunk_every(@max) |> Enum.map(&Enum.join/1)
end

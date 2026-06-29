defmodule TownCrowd.Mentions do
  @moduledoc """
  Pull `@handle` tokens out of a chat line. That's the entire addressing layer —
  the server stays a dumb broadcaster; "who is being addressed" is a convention the
  bots honor, exactly like an IRC/Slack bot.
  """

  @re ~r/@([A-Za-z0-9][A-Za-z0-9_-]*)/

  def parse(text) when is_binary(text) do
    @re
    |> Regex.scan(text)
    |> Enum.map(fn [_, h] -> String.downcase(h) end)
    |> Enum.uniq()
  end

  def parse(_), do: []

  @doc "Heuristic: is this a 'summarize what X discussed' style request?"
  def summary_topic(text) when is_binary(text) do
    if String.match?(text, ~r/summ(ary|ari[sz]e)|recap|what did .* (say|discuss)/i) do
      text
      |> String.replace(@re, "")
      |> String.replace(~r/\b(summary|summari[sz]e|recap|please|about|what|did|say|discuss|with|the)\b/i, "")
      |> String.replace(~r/\s+/, " ")
      |> String.trim()
    else
      nil
    end
  end

  def summary_topic(_), do: nil
end

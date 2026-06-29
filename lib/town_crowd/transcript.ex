defmodule TownCrowd.Transcript do
  @moduledoc """
  The bots' memory of the (otherwise ephemeral) square. Every line they say is
  appended to a JSONL file and held in an ETS table for `search/2`. TownSquare keeps
  no history; this turns the disappearing chatter into a durable, queryable log —
  the raw material for "what did the bots notice" summaries.

  Swap this module for an SQLite-backed one (exqlite) if you want real SQL; keep the
  log/5 + search/2 interface and nothing else changes.
  """

  use GenServer
  @table :town_crowd_transcript

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Record one utterance."
  def log(scene, speaker, model, type, text),
    do: GenServer.cast(__MODULE__, {:log, scene, speaker, model, type, text})

  @doc "Find rows whose text contains `topic`. Optional `speaker:` filter."
  def search(topic, opts \\ []), do: GenServer.call(__MODULE__, {:search, topic, opts})

  @impl true
  def init(_) do
    :ets.new(@table, [:named_table, :ordered_set, :public])
    path = Application.get_env(:town_crowd, :transcript_path, "crowd_transcript.jsonl")
    {:ok, file} = File.open(path, [:append, :utf8])
    {:ok, %{file: file, seq: 0}}
  end

  @impl true
  def handle_cast({:log, scene, speaker, model, type, text}, st) do
    seq = st.seq + 1

    row = %{
      seq: seq,
      ts: System.system_time(:millisecond),
      scene: scene,
      speaker: speaker,
      model: model,
      type: type,
      text: text
    }

    :ets.insert(@table, {seq, row})
    IO.write(st.file, Jason.encode!(row) <> "\n")
    {:noreply, %{st | seq: seq}}
  end

  @impl true
  def handle_call({:search, topic, opts}, _from, st) do
    speaker = Keyword.get(opts, :speaker)
    needle = String.downcase(topic || "")

    rows =
      @table
      |> :ets.tab2list()
      |> Enum.map(fn {_seq, row} -> row end)
      |> Enum.filter(fn row ->
        (is_nil(speaker) or row.speaker == speaker) and
          (needle == "" or String.contains?(String.downcase(row.text), needle))
      end)

    {:reply, rows, st}
  end
end

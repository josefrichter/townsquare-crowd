defmodule TownCrowd.Sandbox do
  @moduledoc """
  A capability sandbox for running model-authored skills with no ambient authority.

  A bot's tools are ordinary functions decided at design time (`TownCrowd.Web`,
  `TownCrowd.Knowledge`). This adds the missing piece: a `run_code` tool where the
  *model* writes JavaScript at runtime and we run it safely. The snippet runs inside a
  JavaScript interpreter (the pure-Rust `boa` engine) compiled to WebAssembly and driven
  by Wasmtime (`wasmex`). A WASM guest has no ambient authority: it can compute, but it
  cannot touch the filesystem, network, clock, or any syscall unless we grant it an
  import. So a hostile or broken snippet can do nothing we did not allow.

  This composes the two kinds of isolation the Crowd already leans on:

    * the **BEAM** contains *faults* — a bot that crashes is restarted alone;
    * **WASM** contains *malice* — a snippet that misbehaves is boxed in.

  ## One warm interpreter, snippets are data

  Compiling the 2.8 MB interpreter (Wasmtime JITs it to native code) costs ~190 ms and
  is fully reusable, so we do it exactly once at startup and keep the compiled module on
  a shared engine. Each `eval/1` then instantiates a fresh, short-lived WASI instance on
  that engine — sub-millisecond to a few ms — feeds the model's JS in on stdin, and reads
  the result off stdout. A fresh instance per call means no state leaks between callers;
  the expensive part (compilation) is never repeated.

  The instance is started by the *calling* process (a bot's supervised Task), so heavy
  compute never blocks this server, and if the caller dies its linked instance dies too.

  Every call returns a plain string and never raises, matching the other tools. The
  interpreter guest lives at `priv/wasm/js_sandbox.wasm`; its Rust source is in
  `native/js_sandbox/` and is rebuilt with `mix town_crowd.build_sandbox` semantics
  (see that directory's README).

  > Not fully solved here: a runaway JS loop is only bounded by `@call_timeout`. A real
  > deployment would also cap guest CPU with Wasmtime fuel or epoch interruption.
  """

  use GenServer
  require Logger

  alias Wasmex.{Engine, Module, Store, Pipe}
  alias Wasmex.Wasi.WasiOptions

  @call_timeout 5_000

  # --- public API -----------------------------------------------------------

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Run a model-authored JavaScript snippet and return its result as a plain string.

  The snippet's completion value (its last expression) is what comes back, e.g.
  `"function f(n){return n<2?n:f(n-1)+f(n-2)} f(20)"` returns `"6765"`. A JS error
  returns a `"JS error: ..."` string; any host-level problem returns `"sandbox: ..."`.
  It never raises.
  """
  def eval(source) when is_binary(source) do
    case GenServer.call(__MODULE__, :guest, @call_timeout) do
      {:ok, engine, module} -> run(engine, module, source)
      {:error, reason} -> "sandbox: #{reason}"
    end
  catch
    :exit, _ -> "sandbox: unavailable"
  end

  def eval(_source), do: "sandbox: invalid skill"

  @doc "Whether the interpreter compiled and the sandbox is ready. For tests/health."
  def ready?, do: match?({:ok, _, _}, GenServer.call(__MODULE__, :guest))

  # --- run (in the caller process, so this server never blocks on compute) ---

  defp run(engine, module, source) do
    {:ok, stdin} = Pipe.new()
    {:ok, stdout} = Pipe.new()
    Pipe.write(stdin, source)
    Pipe.seek(stdin, 0)

    with {:ok, store} <- Store.new_wasi(%WasiOptions{stdin: stdin, stdout: stdout}, nil, engine),
         {:ok, pid} <- Wasmex.start_link(%{module: module, store: store}),
         {:ok, _} <- Wasmex.call_function(pid, :_start, [], @call_timeout) do
      GenServer.stop(pid)
      Pipe.seek(stdout, 0)
      output(Pipe.read(stdout))
    else
      {:error, reason} -> "sandbox error: #{summarize(reason)}"
    end
  catch
    :exit, _ -> "sandbox error: skill aborted"
  end

  defp output(text) when is_binary(text) do
    case String.trim(text) do
      "" -> "(no output)"
      trimmed -> trimmed
    end
  end

  defp output(_), do: "(no output)"

  defp summarize(reason) when is_binary(reason),
    do: reason |> String.split("\n", parts: 2) |> hd() |> String.trim()

  defp summarize(reason), do: inspect(reason)

  # --- server: compile the interpreter once, hold engine + module -----------

  @impl true
  def init(_opts) do
    # Compile lazily-blocking at boot: ~190ms once, then every eval reuses it.
    path = Path.join(:code.priv_dir(:town_crowd), "wasm/js_sandbox.wasm")

    with {:ok, bytes} <- File.read(path),
         {:ok, engine} <- Engine.new(%Wasmex.EngineConfig{}),
         {:ok, cstore} <- Store.new(nil, engine),
         {:ok, module} <- Module.compile(cstore, bytes) do
      {:ok, %{engine: engine, module: module}}
    else
      other ->
        Logger.warning("Sandbox: interpreter not loaded (#{inspect(other)}); run_code disabled")
        {:ok, %{error: "interpreter unavailable"}}
    end
  end

  @impl true
  def handle_call(:guest, _from, %{engine: e, module: m} = state),
    do: {:reply, {:ok, e, m}, state}

  def handle_call(:guest, _from, %{error: reason} = state),
    do: {:reply, {:error, reason}, state}
end

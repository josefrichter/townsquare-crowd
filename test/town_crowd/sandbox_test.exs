defmodule TownCrowd.SandboxTest do
  use ExUnit.Case, async: false

  # A "skill" is now plain JavaScript, the kind a small model actually writes. It runs
  # in a boa JS interpreter compiled to WASM, with no ambient authority.

  @moduletag :sandbox

  setup do
    unless TownCrowd.Sandbox.ready?() do
      raise "interpreter not built — run: (cd native/js_sandbox && cargo build --release --target wasm32-wasip1) and copy the .wasm to priv/wasm/"
    end

    :ok
  end

  test "runs a model-authored JS snippet and returns its result" do
    assert TownCrowd.Sandbox.eval("2 + 3 * 7") == "23"
    assert TownCrowd.Sandbox.eval("[1,2,3].map(x => x * x).join(',')") == "1,4,9"

    fib = "function f(n){ return n < 2 ? n : f(n-1) + f(n-2) } f(20)"
    assert TownCrowd.Sandbox.eval(fib) == "6765"
  end

  test "the same interpreter is reused across calls (no per-call recompile)" do
    # 20 calls that each take a few ms at most; a recompile would be ~190ms each.
    {us, _} = :timer.tc(fn -> for _ <- 1..20, do: TownCrowd.Sandbox.eval("1 + 1") end)
    assert us / 1000 < 500, "20 warm calls took #{Float.round(us / 1000, 1)}ms"
  end

  test "a JS error is returned as a string, never raised" do
    assert TownCrowd.Sandbox.eval("throw new Error('boom')") =~ "error"
    # and the sandbox keeps working afterwards
    assert TownCrowd.Sandbox.eval("40 + 2") == "42"
  end

  test "no ambient authority: no Node/host globals in the sandbox" do
    assert TownCrowd.Sandbox.eval("typeof require") == "undefined"
    assert TownCrowd.Sandbox.eval("typeof process") == "undefined"
    assert TownCrowd.Sandbox.eval("typeof fetch") == "undefined"
  end

  test "junk input never raises" do
    assert TownCrowd.Sandbox.eval(123) == "sandbox: invalid skill"
    assert TownCrowd.Sandbox.eval("this is (not valid javascript") =~ "error"
  end
end

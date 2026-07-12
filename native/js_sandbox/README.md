# js_sandbox

The WebAssembly guest for `TownCrowd.Sandbox`: a JavaScript interpreter (the pure-Rust
[boa](https://github.com/boa-dev/boa) engine) compiled to `wasm32-wasip1`. It reads a JS
snippet from stdin, evaluates it, and prints the result to stdout. It has no ambient
authority beyond the WASI stdio the host grants, so a bot can run model-authored JS in it
safely.

## Build

Needs a Rust toolchain via `rustup` (not Homebrew Rust, which has no wasm target):

```sh
rustup target add wasm32-wasip1
cargo build --release --target wasm32-wasip1
cp target/wasm32-wasip1/release/js_sandbox.wasm ../../priv/wasm/js_sandbox.wasm
```

The committed artifact lives at `priv/wasm/js_sandbox.wasm`; `target/` is gitignored.

## Swapping the engine

boa is pure Rust and easy to build, but it's a from-scratch engine and not the fastest.
To use QuickJS instead (faster, more complete), you'd compile QuickJS's C to `wasm32-wasi`
with the wasi-sdk toolchain and keep the same stdin/stdout contract; nothing on the Elixir
side changes.

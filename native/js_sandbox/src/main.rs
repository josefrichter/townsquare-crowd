// A JS interpreter as a WASI command: read a script from stdin, eval it with boa
// (a pure-Rust JS engine), print the result to stdout. No ambient authority beyond
// the WASI stdio the host grants. This is the sandbox guest a model actually writes for.
use boa_engine::{Context, Source};
use std::io::{self, Read, Write};

fn main() {
    let mut src = String::new();
    if io::stdin().read_to_string(&mut src).is_err() {
        let _ = write!(io::stdout(), "sandbox: could not read input");
        return;
    }
    let mut ctx = Context::default();
    let out = match ctx.eval(Source::from_bytes(src.as_bytes())) {
        // Coerce the completion value with JS String() semantics so the caller gets a
        // clean result: 23, "1,4,9" (no quotes), undefined, [object Object], etc.
        Ok(v) => match v.to_string(&mut ctx) {
            Ok(s) => s.to_std_string_escaped(),
            Err(_) => "sandbox: result is not representable as text".to_string(),
        },
        Err(e) => format!("JS error: {e}"),
    };
    let _ = io::stdout().write_all(out.as_bytes());
}

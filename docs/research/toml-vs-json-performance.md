# TOML versus JSON parser performance context

## Scope

TOML and JSON do not have a portable performance ratio. Parser implementation,
target representation, input shape, and TOML-only semantics (temporal values,
dotted keys, comments, and table rules) dominate. Compare parse-only, generic
DOM construction, and typed binding separately.

## First-party same-workload data

The most useful published comparison found is a `toml-rs` maintainer benchmark
of `Cargo.web-sys.toml` and JSON generated from the decoded TOML data:

| Configuration | TOML | `serde_json` | TOML / JSON |
| --- | ---: | ---: | ---: |
| Current default | 501 us | 259 us | 1.93x |
| Current with `preserve_order` | 320 us | 158 us | 2.03x |
| Older TOML 0.5 table | 939 us | 259 us | 3.63x |

This measures parsing plus creation/deserialization into intermediate values,
not tokenization alone. The inputs and target types are close in intent but not
byte-identical, so these are useful context rather than a universal constant.

Sources:

- [toml 0.9 maintainer report](https://epage.github.io/blog/2025/07/toml-09/)
- [toml-rs Cargo benchmark source](https://github.com/toml-rs/toml/blob/main/crates/benchmarks/benches/0-cargo.rs)
- [toml-rs benchmark manifest](https://github.com/toml-rs/toml/blob/main/crates/benchmarks/Cargo.toml)

## What other primary-source suites establish

- [BurntSushi/toml](https://github.com/BurntSushi/toml/blob/master/bench_test.go)
  benchmarks TOML decoding but does not include an equivalent `encoding/json`
  run, so it cannot establish a TOML/JSON ratio.
- [`go-toml` v2](https://github.com/pelletier/go-toml/blob/v2/README.md)
  reports several-fold TOML-vs-TOML differences across implementations. That
  demonstrates implementation choice can move performance by an order of
  magnitude; it is not TOML-vs-JSON evidence.
- [Tomli's benchmark runner](https://github.com/hukkin/tomli/blob/master/benchmark/run.py)
  is TOML-only; [PEP 680](https://peps.python.org/pep-0680/) documents that
  Python's `tomllib` derives from Tomli. Neither publishes an equivalent
  `json.loads` result.

## Updated local `odin_config` comparison

The original comparison harness was recovered and retained under
`../odin_config/benchmarks`. Its JSON and TOML fixtures encode the same 21
string values grouped into five sections. Each timed operation parses the
in-memory input, converts it into an owning `config.Document`, and destroys all
owners. The Reference Odin compiler is `dev-2026-07:2c25fb924`; builds use
`-o:speed -vet -vet-style -warnings-as-errors`.

Three complete harness invocations, each containing one warmup and seven batches
of 50,000 operations per format, produced these medians of invocation medians:

| Format | Input | Median time | Throughput | Relative to JSON |
| --- | ---: | ---: | ---: | ---: |
| JSON | 509 B | 5.50 us/op | 88.3 MiB/s | 1.00x |
| INI | 436 B | 3.96 us/op | 105.0 MiB/s | 0.72x |
| TOML | 478 B | 32.91 us/op | 13.85 MiB/s | 5.99x |

The pre-optimization observation from the same harness was 71.96 us/op for TOML
and 5.45 us/op for JSON, or 13.20x. The parser work therefore reduced the full
TOML integration time by about 54.3% and the measured TOML/JSON ratio from 13.20x
to 5.99x. JSON timing remained effectively unchanged.

A forwarding allocator around one complete integration operation observed 5
allocation requests for JSON and 82 for TOML. Requested-byte totals were 131,464
for JSON and 76,224 for TOML, but those byte totals reflect different dynamic
arena growth strategies and are not peak live-byte measurements.

The updated 5.99x ratio is still above the published Rust 1.9--3.6x points. It is
an integration comparison, not tokenization alone: both sides include generic
DOM creation, conversion into `odin_config`, and owner destruction. The inputs
represent identical logical values but are not byte-identical.

Reproduce from `odin_config` with:

```sh
odin run benchmarks -o:speed -vet -vet-style -warnings-as-errors
```

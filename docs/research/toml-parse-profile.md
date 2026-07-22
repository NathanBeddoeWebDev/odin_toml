# `parse_string` profile on the `odin_config` workload

## Workload and method

The profiled input is the original `odin_config` comparison fixture: 478 bytes,
five ordinary table headers, 21 bare-key assignments, and 21 quoted ASCII
string values. It contains no numeric or temporal values.

The parser was built with Reference Odin `dev-2026-07:2c25fb924`, `-o:speed`,
and debug symbols on an Apple M4 Max. Timings use seven batches of 20,000
operations after warmup. CPU evidence comes from 7,696 one-millisecond samples
collected by macOS `sample`. Allocation counts come from a forwarding allocator
around one successful parse and destruction.

The benchmark fixtures and parser variants were temporary and did not modify the
repository. Synthetic variants intentionally invalidate diagnostics and are
used only to estimate costs.

## Result

A batched phase measurement attributed about 67.0 us to `parse_string` and only
0.50 us to `destroy_document`. The integration's roughly 72 us is therefore
primarily parser time, not destruction or `odin_config` conversion.

No decimal, float, big-number, or temporal procedure appeared in the CPU sample,
as expected for this all-string input.

### Ranked costs

| Experiment | Median parse + destroy | Change from paired control |
| --- | ---: | ---: |
| Current parser | 65.1--66.2 us | baseline |
| Skip unused binding-range creation | 59.3 us | 8.9% faster |
| Constant-time source positions (synthetic) | 42.9 us | about 35% faster |
| Empty diagnostic path snapshots (synthetic) | 58.1 us | about 12% faster |
| Both synthetic diagnostic experiments | 34.5 us | about 48% faster |
| Geometric temporary-node growth | 62.0--63.3 us | about 4% faster |

The synthetic experiments are attribution probes, not valid patches: the first
produces incorrect line/column ranges and the second removes diagnostic paths.

## Findings

### 1. Source position construction dominates

`source_range` calls `source_position_at` for both endpoints, and each endpoint
scan restarts at byte zero (`parser.odin:55-81`). This valid parse made 188
position calls and rescanned 44,798 input bytes—about 94 times the 478-byte
input. `source_position_at` alone occupied 2,422 of 7,696 top-of-stack CPU
samples (31.5%).

Ordinary assignments eagerly construct definition, key, and value ranges
(`parser_tables.odin:766-775`). `parser_capture_value_range` also constructs a
range before `parser_append_binding_range` discovers that ordinary parsing is
not retaining ranges (`parser_tables.odin:72-74, 140-146`). Adding an early
`!state.capture_binding_ranges` guard to the temporary variant reduced the
workload by 8.9% without changing the document-building path.

The larger opportunity is to keep byte offsets in temporary parser nodes and
resolve line/column only when producing an error or retained binding ranges.
That preserves strict diagnostics while removing repeated prefix scans from the
success path.

### 2. Diagnostic path snapshots are expensive success-path values

The valid parse created 104 `Parse_Diagnostic_Path` snapshots. Each public path
value is 3,848 bytes on this build, so initialization/copying touches at least
about 400 KiB per 478-byte parse before accounting for further by-value
propagation. `parser_path_snapshot` is called during successful key and value
preflight, decoding, and container construction (`parser_containers.odin:40-74`).

The parser also clears the unused tail of a 257-segment path stack when copying
an active path (`parser_tables.odin:373-379`). A production optimization should
snapshot the compact active path only when an error is materialized, rather
than passing a full public diagnostic value through successful parsing.

### 3. Allocation count is high, but allocator CPU is secondary

One parse issued 99 allocations requesting 69,400 bytes. Forty-six transient
allocations had already been freed when `parse_string` returned; all 99 were
released after `destroy_document`.

| Allocation purpose | Calls | Requested bytes |
| --- | ---: | ---: |
| Keys and string values | 47 | 336 |
| Exact-growth semantic table buffers | 26 | 4,480 |
| Exact-growth temporary parser-node buffers | 26 | 64,584 |

`parser_append_node` reallocates and copies an exact `len + 1` array for every
node (`parser_tables.odin:195-221`). Geometric capacity reduced this probe to 79
allocations and 16,408 requested bytes, but improved CPU by only about 4%.
It remains worthwhile after diagnostic work because it removes 20 allocator
round trips and 53 KiB of requested transient storage per parse.

Semantic tables use the same exact-growth policy (`parser_containers.odin:201-229`),
but account for much less requested storage on this evenly distributed fixture.

### 4. String and UTF-8 work is not the first target

Every quoted value is scanned once for decoded size and again to write its owned
allocation (`parser.odin:579-603`). The parser also performs mandatory whole-input
UTF-8 validation (`parser.odin:169-236, 1461-1464`). These costs were visible but
well below source positions and diagnostic bookkeeping for this ASCII fixture.

## Recommended optimization order

1. Add the ordinary-parse early guard in `parser_capture_value_range`; it is the
   smallest success-path fix and measured 8.9% on this workload.
2. Store byte ranges in temporary parser state and lazily construct line/column
   ranges for errors and ranged parsing.
3. Defer construction of public diagnostic path snapshots until an error is
   emitted; stop clearing unused fixed-stack tails on successful shallow paths.
4. Give `Parser_Node_Array` geometric capacity while preserving the package's
   explicit allocator and unsupported-mode contracts.
5. Reprofile before changing string decoding, UTF-8 validation, or semantic
   table representation.

The first two diagnostic probes together establish an approximate 34.5 us
parse-plus-destroy ceiling for this fixture before deeper parser/data-model
work. They do not establish the performance of a diagnostics-correct
implementation.

## Follow-up implementation measurements

A later implementation pass used the recovered `../odin_config/benchmarks`
harness with the same compiler and fixture. One complete seven-sample invocation
was run before the pass and after each ordinary-parse change:

| Checkpoint | Complete TOML | Semantic parse | Parse allocations |
| --- | ---: | ---: | ---: |
| Commit `266fd1d` baseline | 32.78 us | 28.07 us | 79 |
| Compact lazy diagnostic paths | 29.55 us | 24.25 us | 79 |
| Geometric semantic Table/Array growth | 27.37 us | 21.75 us | 73 |

Compact paths retain only source byte ranges or array indexes while parsing.
Exact public key snapshots, including decoded escapes and UTF-8-safe long-key
boundaries, are reconstructed without allocation only when an error is emitted.
The change also replaces the full public-path sentinel passed by value and stops
clearing inactive 257-segment stack tails.

Three final comparison invocations produced a median of invocation medians of
27.80 us complete and 21.87 us for semantic parse, with 73 semantic-parse
allocation requests. Relative to the 32.78/28.07 us pass baseline, that is about
15.2% lower complete time and 22.1% lower semantic-parse time. Allocation counts
fell by six because geometric semantic buffers reuse spare capacity.

The separate five-sample in-repository recorder measured typed unmarshal at
14.37 us before geometric binding-range scratch growth and 13.57 us afterward
(5.6% lower). Its codec-heavy case fell from 213.43 us to 192.21 us (9.9%). The
ordinary parse category moved from 19.48 us to 19.76 us, consistent with noise
because ordinary parsing does not retain binding ranges. These observations are
non-gating and requested-byte totals remain cumulative rather than peak-live
measurements.

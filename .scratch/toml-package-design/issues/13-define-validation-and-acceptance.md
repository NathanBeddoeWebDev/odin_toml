# Define validation and acceptance criteria

Type: grilling
Status: resolved
Blocked by: 04, 09, 10, 11, 12

## Question

Which official corpus suites, focused grammar cases, property/round-trip checks, reflection and tag matrices, allocator-failure injections, leak checks, writer failures, fuzz cases, platform checks, and deterministic-output assertions must pass before the package implementation satisfies the approved design?

## Answer

Adopt the validation shape shared by mature TOML libraries and Reference Odin core: the official language corpus is a mandatory but insufficient base; focused public-API and exact-output tests lock down package policy; semantic round trips and fuzzing exercise composition; and Odin-specific allocator, writer, sanitizer, and target tests prove the manual-memory contracts. The supporting precedent is recorded in [Validation and acceptance precedent](../research/validation-acceptance-precedent.md).

The implementation satisfies this design only when every mandatory gate below passes on the exact Reference Odin revision. A check may run in a different CI tier for cost, but “scheduled” does not mean optional: a release requires a green result since the last relevant source change and no unresolved minimized fuzz or fault-injection failure. There are no silent exclusions, flaky retries that turn red into green, or aggregate pass percentages. Every discovered defect receives a stable regression case before it is considered fixed.

### Equality and test-oracle conventions

Use a package-test semantic equality helper rather than source-text equality. It compares value alternatives exactly, table entry order and keys exactly, array order exactly, temporal fields exactly, and finite floats and signed zero by binary64 bits. All NaN bit patterns compare as one TOML-semantic NaN class because parse and canonical encoding deliberately discard host NaN sign/payload metadata. Application-value round trips likewise ignore pointer identity and map iteration/storage identity while comparing all represented TOML values.

Test expected public error values structurally, not by a human-formatted message. Diagnostics must match their exact union alternative, detail enum, source range, related range, path contents and truncation metadata, source/destination type information, and wrapped `temporal.Error`, allocator error, callback code, or `io.Error`. Test helpers may allocate, but the operation under test must continue to satisfy its allocation-free-error contract.

### Official TOML 1.1 conformance gate

Use issue 04's integration and deliberately strengthen its temporary-skip allowance to zero total skips for initial acceptance:

- `toml-lang/toml-test` v2.2.0 at commit `ce08da1ddb075d1c7596d663c7fcba9a2ae02c5c`;
- literal `-toml=1.1.0`, never the runner default, `latest`, or an inferred directory set;
- separate test-only decoder and encoder executables using the public parse and unparse APIs;
- zero valid-decoder failures, zero invalid-decoder failures, zero encoder failures, and zero skips;
- exact invalid-decoder exit status 1, successful stderr silence, and the adapter protocol rules from issue 04;
- a preserved JSON report containing the pin, command, compiler revision, platform, and result.

Run the equivalent of:

```sh
toml-test test \
  -toml=1.1.0 \
  -decoder=./build/toml_test_decoder \
  -encoder=./build/toml_test_encoder \
  -timeout=5s \
  -parallel=4 \
  -color=never \
  -json
```

Locally test both adapters as ordinary programs. The decoder adapter must preserve all eight tagged scalar kinds, exact keys, and array order. The encoder adapter must reject malformed JSON, unknown or missing tags, non-string tagged scalar values, invalid scalar text, out-of-range integers, invalid temporals, non-table roots, and trailing adapter input. These negative adapter cases are mandatory because the pinned official encoder runner supplies only valid tagged JSON.

Do not vendor a mutable copy of the corpus or freeze expected test counts in assertions. The immutable manifest and zero-failure/zero-skip report are authoritative. Updating the corpus requires a reviewed pin change, regenerated provenance and license metadata, and a fresh complete result.

### Focused strict-parser and temporal matrix

The official corpus establishes broad semantic compatibility, but local table-driven cases must exercise the exact parser and diagnostic contracts. For every rejection family include a nearest valid neighbor, and for every accepted 1.1 extension include a corresponding form that a 1.0-only or prefix parser would mishandle.

Required lexical and grammar coverage is:

- empty, whitespace-only, comment-only, LF, CRLF, EOF-without-newline, bare CR, BOM, TAB/SPACE versus Unicode lookalike whitespace, and complete-input/trailing-token rejection;
- valid UTF-8 at one-, two-, three-, and four-byte boundaries and malformed leading bytes, stray/bad continuation bytes, overlong forms, surrogate encodings, values above U+10FFFF, and truncation in keys, strings, comments, arrays, and EOF;
- bare, basic-quoted, and literal-quoted keys; empty quoted keys; numeric-looking keys; dots inside versus outside quotes; escaped-equivalent duplicate keys; case and normalization-distinct Unicode keys; malformed and multiline keys;
- every basic/literal and single/multiline string delimiter boundary, one/two/three quote runs, opening-newline trimming, line-ending-backslash folding, every named and numeric escape, invalid escape lengths/digits/scalars, raw forbidden controls, escaped NUL/C0/DEL, and LF/CRLF multiline normalization;
- decimal, hexadecimal, octal, and binary integer boundaries, signs, leading zeroes, underscore positions, invalid digits, exact `i64` minimum/maximum, and one-step overflow on both sides;
- finite-float grammar boundaries, exponents and underscores, positive/negative zero, subnormals, underflow to signed zero, finite overflow rejection, explicit infinities, accepted NaN spellings and normalization, and valid-token-prefix suffix attacks;
- exact lowercase booleans and every incomplete, suffixed, or case-varied near miss;
- arrays and inline tables at empty, singleton, nested, multiline, comment, separator, and trailing-comma boundaries, including heterogeneous arrays and every missing/double-comma and closing-delimiter EOF position;
- root, implicit, standard-header, dotted-defined, inline-sealed, scalar/static-array, and array-of-tables state transitions; valid late implicit-parent definition; decoded-path duplicates across spellings/forms; scalar traversal; repeated/redefined tables; inline extension; static-array/table/AoT conflicts; nested AoT-before-parent rejection; repeated AoT append; and child binding to the latest parent element;
- semantic insertion order for direct keys, implicit parents, headers, dotted keys, first and later AoT elements, and syntactically different documents that produce the same ordered semantic tree.

For all four temporal forms test fixed widths, year `0000` and `9999`, Gregorian leap-year/month/day boundaries, hours/minutes/offset bounds, omitted seconds, fraction-without-seconds rejection, separators `T`/`t`/space, `Z`/`z`/signed offsets, known zero versus unknown `-00:00`, second `60`, one through nine fraction digits, more-than-nine-digit truncation without rounding, and values adjacent to every invalid component. The sibling `temporal` suite separately covers every `validate` error, civil comparison, instant comparison including leap-second limitations, known/unknown offsets, and every successful and failing `core:time`/`datetime` conversion without consulting machine timezone state.

Depth tests construct tables, dotted paths, inline tables, arrays, and mixed table/index paths at selected limits 1, default 128, and hard maximum 256. The child exactly at the limit succeeds and the next child fails before installation. Test invalid option values, checked size arithmetic through test seams or feasible boundary inputs, very long keys/strings and wide arrays without an invented fixed limit, and long flat input that must not consume recursive stack in proportion to bytes or token count.

### Diagnostics and failure precedence

Provide at least one direct fixture for every package-defined parse, unparse, marshal, and unmarshal configuration, diagnostic, data, limit, codec, allocator, and writer union alternative and detail enum. “Every alternative” does not mean every possible value of the wrapped external `runtime.Allocator_Error` or `io.Error` types: use `.Out_Of_Memory` for ordinal allocation sweeps, separately propagate `.Invalid_Argument` through representative owner-producing and scratch-allocating public calls, exercise `.Mode_Not_Implemented` where the destruction fallback permits it, and use at least two distinct explicit `io.Error` values to prove exact propagation rather than collapsing. Marshal and unmarshal codec failures likewise use at least two distinct nonzero callback codes. Parser fixtures must cover every `Parse_Lexical_Error`, `Parse_Syntax` expectation class, `Parse_Value_Error_Kind`, `Parse_Definition_Error_Kind`, definition form pairing that the parser can produce, `Parse_Limit_Error`, and wrapped `temporal.Error`.

Coordinate tests use ASCII, multibyte Unicode, TAB, LF, CRLF, malformed UTF-8, empty insertion ranges at EOF, and escapes whose decoded width differs from source width. They assert zero-based byte offsets, one-based scalar line/column, half-open ranges, the first malformed UTF-8 leading-byte rule, and authoritative source slices from byte ranges.

Path tests cover:

- empty and ordinary key/index paths;
- quoted dots as one key segment;
- prospective array indexes and uncommitted destinations;
- active-table component source ranges and definition-related ranges;
- keys of exactly 64 and more than 64 decoded bytes, including multibyte boundaries that cannot be split;
- paths of exactly 32 and more than 32 segments, verifying first-eight/final-24 storage and exact omission counts;
- encode paths borrowed from documents, RTTI, and application values while those sources remain valid.

For every precedence rule in issues 09–12, combine at least two independently invalid conditions and assert the selected first error: allocator/options/input encoding; source-order parse failures; writer options/configuration; canonical traversal data failures; struct-plan versus value failures; map-key planning; unknown fields; destination state; codec failure versus ordinary binding; allocation failure at the point ordered work can no longer continue; and explicit writer error after successful preflight. Parse and typed errors must remain usable after releasing the input and package temporary tree.

### Semantic document, deterministic encoder, and exact-byte goldens

Test initialized empty documents separately from zero/uninitialized documents and containers. Exercise deep clone, destroy idempotence, exact allocator retention, `get`, replacing and appending `set`, stable `remove`, remove/reinsert order, borrowed lookup validity before mutation, deep non-aliasing after clone, and rejection of caller-constructed duplicate, invalid-text, invalid-union/container, cycle, alias, and allocator-mismatch trees.

Byte-for-byte golden tests lock every rule from issue 10:

- empty output and one root assignment per LF-terminated line;
- quoted basic-string keys for empty, dotted, numeric-looking, control-containing, and Unicode keys;
- every string escape choice, uppercase `\xHH`, direct valid Unicode, and rejection rather than repair of invalid text;
- exact empty/non-empty array and inline-table spacing and recursively all-inline representation;
- minimal decimal integers including `i64` minimum;
- `0.0`, `-0.0`, infinities, canonical `nan`, fixed/scientific tie selection, exponent spelling, and shortest correctly rounded finite binary64 spelling;
- all four canonical temporal forms, seconds, fraction trimming, leap second, known UTC, nonzero offset, and unknown offset;
- semantic table insertion order, struct declaration/flatten expansion order, array order, and unsigned-UTF-8 lexical map-key order;
- LF output on every target, including Windows, while parse-time raw multiline normalization follows the target convention.

Pin the test-only float oracle to Ulf Adams's C Ryu implementation at commit `4c0618b0e44f7ef027ebae05d2cc7812048f7c8f`. A test wrapper extracts Ryu's shortest decimal significand and exponent, then independently renders the issue-10 fixed and normalized-scientific candidates and applies the package's length/fixed-tie rule. Use `ryu/tests/d2s_test.cc` at that same commit as the named edge-vector source for zeroes, subnormals, normal/subnormal and exponent transitions, halfway/tie cases, integer-looking floats, and maximum finite values, supplemented by deterministic raw-bit sampling. Record the full commit, acquisition method, and Apache-2.0/Boost-1.0 license provenance beside the test tool; it is never a runtime dependency. Assert both identical reparse bits and exact bytes from this oracle—self-round-tripping alone is not enough to prove shortest canonical spelling.

Construct maps in multiple insertion histories and repeat encoding in separate invocations so host map iteration cannot leak into bytes. The allocated and writer forms must be byte-identical for every golden. Successful output must parse as strict TOML 1.1 and canonical re-encoding of that parsed document must reproduce the same bytes.

### Required property and round-trip checks

Run deterministic, seed-reporting generators over bounded valid semantic trees containing every scalar alternative, empty/non-empty containers, unusual valid keys/text, mixed arrays, and depths around configured boundaries. Required properties are:

1. `unparse(valid_document) -> parse` preserves semantic equality, modulo NaN metadata.
2. `parse(valid_text) -> unparse -> parse` preserves the first parsed semantic tree.
3. `unparse -> parse -> unparse` is byte-idempotent.
4. Allocated-result and writer forms produce identical bytes.
5. Deep clone preserves semantic equality/order and has no backing aliases to the source.
6. Repeated encoding of the same source/options is byte-identical.
7. For types supported in both typed directions, `marshal -> unmarshal` preserves represented value semantics after zero-state cleanup rules, ignoring application pointer/map identity; one-way `any` and direction-only codecs are excluded explicitly rather than forced into a false property.
8. A paired custom codec's semantic value agrees with generic canonical validation and round-trips according to that codec's application contract.

Generated malformed trees and application graphs must either produce the documented first error or succeed without panic, invalid output, unbounded recursion, or leaked package state. Preserve the random seed in failure output and support replay through `ODIN_TEST_RANDOM_SEED`, following Reference Odin's deterministic fuzz-test convention.

### Reflection, tags, containers, and codec registry matrix

Use table-driven marshal and unmarshal matrices rather than a handful of representative structs. They must cover:

- every TOML source kind crossed with each accepted and rejected Odin scalar category; all signed/unsigned widths and named/distinct forms at fit, rounding, underflow, and overflow boundaries; exact temporal types and rejection of wrappers/cross-kind coercions;
- valid struct tags for absent, empty, rename, literal dotted name, ignore, and `omitempty`; every empty, unknown, duplicate, trailing, whitespace-padded, and malformed option/tag-list form; duplicate `toml` entries; invalid UTF-8 names; and ignored unsupported fields;
- ordinary fields, named `using`, recursively anonymous `using _` flattening, wrapper ignore, declaration-order expansion, and effective-name collisions at each nesting shape;
- every `omitempty` category, including signed float zero, nil wrappers, empty versus non-empty containers, non-nil wrappers around empty values, and structs/temporals that are never empty;
- eligible and ineligible map keys, empty maps with unsupported declared values, lexical sorting, converted-key collision, nil versus initialized map, and destination key ownership;
- fixed and enumerated arrays at exact and wrong lengths; slices and dynamic arrays at nil/empty/non-empty states; zero-sized elements; unsupported declared element types even when empty; and excluded matrix/SIMD/SoA/fixed-capacity kinds;
- ordinary pointers including zero-sized pointees, optional unions, unsupported unions, `any` marshal and unmarshal asymmetry, active recursion cycles, and repeated acyclic references encoded by value;
- every generic unsupported kind and root-shape rejection;
- missing fields, ignored fields, recursive unknown-field acceptance/rejection, clean versus nonzero matched destination ownership, preflight errors leaving the complete destination unchanged, and installation failures leaving only documented caller-cleanable commit units.

Registry tests cover initialization/destruction idempotence, nil allocator, nil/uninitialized registry, invalid type id, nil callback, duplicate same-direction registration, independent directional registration, allocator failure during map growth, exact-`typeid` precedence before named/generic/temporal handling, wrapper lookup order, no map-key codec lookup, `omitempty` before lookup, exact-once deterministic callback order, cached marshal results, callback user data, successful semantic-value ownership, invalid returned semantic values, exact propagation of at least two allocator errors, preservation of at least two distinct callback failure codes in both typed directions, callback failure wrapping/path/range, transactional cleanup of a failing unmarshal slot, and earlier generic commit units remaining caller-owned. Read-only use of one frozen registry from concurrent marshal/unmarshal calls must pass a stress test with immutable callback `user_data` (or caller-synchronized mutable state), so the fixture does not introduce an application-owned race. Registry mutation/destruction during use remains a documented caller violation and is not made race-safe by the package.

### Exhaustive allocator, ownership, and leak gates

Follow the fail-at-N pattern used by Reference Odin core. Wrap a `mem.Tracking_Allocator` in a deterministic allocator that counts `.Alloc`, `.Alloc_Non_Zeroed`, `.Resize`, and `.Resize_Non_Zeroed`. First run a representative success to obtain its allocation-attempt count `N`; then rerun with each ordinal `0..<N` forced to return a chosen non-`.None` `runtime.Allocator_Error`, plus `fail_at == N` to prove success after all sites. Do not assume `N` is equal across build modes or targets.

Apply ordinal sweeps to every allocating ownership workflow and enough shaped inputs to enter each distinct phase:

- `parse_bytes` and `parse_string`, including decoded text, nested containers, parser lookup/definition sidecars, and AoT state;
- `clone_document` and `clone_value` over all owning alternatives;
- absent-key append and existing-key replacement through `set`, including dynamic-array growth;
- `unparse` and `marshal`, including validation scratch, map sorting, codec-produced values, exact-size result allocation, and final sizing/copy paths;
- both writer forms when preflight/sorting/codec scratch allocates;
- typed unmarshal into structs, strings, slices, dynamic arrays, maps, pointers, optional unions, nested commit units, and custom-codec slots;
- codec-registry initialization and each direction's growth/registration.

At every ordinal assert the exact allocator error, nil/zero result for transactional owner-producing operations, unchanged clone source and failed `set` target, no writer call for preflight allocation failure, and zero live allocations after cleaning the documented owner. Typed-unmarshal installation failures may leave earlier installed units; recursively clean that partial destination with the original allocator and then require the tracking allocator to be empty. A failing custom unmarshaler must leave its own supplied slot exactly zero.

Run lifecycle suites with default heap, tracking heap, the fail-at-N wrapper, and both externally reclaimed allocator branches from issue 08. A feature-reporting arena whose capabilities omit `.Free` must be logically zeroed without any individual-free attempt. A wrapper for which allocator feature reporting is unavailable must observe exactly the permitted first ordinary release attempt returning `.Mode_Not_Implemented`, then no further individual releases while the owner is logically zeroed. Both reclaim physical storage through their external reset/destruction lifetime and must observe no ambient free. Deliberately replace `context.allocator` with a rejecting sentinel while passing a valid explicit allocator to catch ambient fallback. Verify package-owned storage and registry storage use only their recorded/supplied allocators and that callback escaping allocations use the callback allocator.

Every ordinary test process runs with Odin bad-memory failure enabled. Normal builds run under AddressSanitizer where the Reference compiler/target supports it. Test success and every error path for leaks, double frees, invalid frees, use-after-free, and result/destructor idempotence; an expected external arena lifetime is accounted for explicitly rather than hidden as a leak waiver.

### Writer count/error injection

Use a scripted `io.Writer` that records every requested slice, accepted prefix, return count, and error. Obtain a successful call trace for a representative multi-value document, then inject failure at every writer-call ordinal for both semantic and typed writer APIs.

The matrix includes:

- full count and nil error;
- zero or proper-prefix count with nil error, yielding `.Short_Write`;
- negative and greater-than-request count, yielding `.Invalid_Write`;
- explicit non-nil errors with zero, proper-prefix, and full accepted counts, preserving the exact `io.Error` even when bytes were accepted;
- failure on each successive call without retrying or consuming one writer result twice.

In all cases, recorded accepted bytes must be exactly a prefix of the canonical golden output, and package scratch/codec values must be cleaned. Empty output makes zero writer calls. Every configuration, source-data, depth, ownership, codec, and preflight allocation error makes zero writer calls. Allocated-return forms never report `io.Error`. A successful writer call is byte-identical to the allocated form.

### Fuzz and adversarial robustness gates

Include deterministic structure-aware randomized tests in the ordinary Odin suite, using bounded input and a reported/replayable seed. At minimum run 4,096 arbitrary-byte cases and 2,048 mutations of valid, deeply structured seeds per test invocation, matching the exact initial budgets in [Reference Odin's deterministic ASN.1 fuzz tests](https://github.com/odin-lang/Odin/blob/2c25fb92420bfa31da62e2194b0cc2cb8bd54cf8/tests/core/encoding/asn1/fuzz_asn1.odin#L11-L14). Accepted input is always subjected to the semantic and canonical round-trip oracles above; rejection must be clean and leak-free.

Provide coverage-guided targets for:

1. arbitrary `[]byte` strict parse, including invalid UTF-8;
2. valid UTF-8 parse with truncation, delimiter, escape, newline, numeric, and definition-state mutations;
3. parse-success followed by unparse/reparse semantic equality and canonical byte idempotence;
4. generated semantic trees through clone/unparse/writer validation, including bounded malformed graphs constructed safely by the harness;
5. representative typed marshal/unmarshal and custom-codec shapes;
6. malformed tagged-JSON adapter input.

Seed them with the official valid/invalid corpus, focused local fixtures, canonical encoder goldens, depth-boundary documents, and every minimized prior failure. On each pull request, build the fuzz targets with sanitizers and run at least one aggregate 300-second smoke campaign that exercises every target, following mature Go TOML-library CIFuzz precedent. This fixed smoke campaign is the initial objective fuzz-duration gate. Longer continuous or scheduled campaigns are recommended but have no invented minimum; any crash, hang, sanitizer finding, invariant violation, or unresolved artifact from any campaign blocks release. Save the seed/corpus artifact and add every minimized discovery to deterministic regression tests.

### Platform, compiler, build-mode, and concurrency gate

Initially support exactly the Reference Odin revision `dev-2026-07:2c25fb924`; older compiler compatibility is not an acceptance requirement. Record `odin version` and `odin report` in CI artifacts.

The initial package deliberately promises the following full runtime matrix, combining the three desktop OS families common to mature TOML libraries with the amd64/arm64 coverage used by Reference Odin where hosted runners exist:

- Linux amd64 and arm64;
- macOS amd64 and arm64;
- Windows amd64.

Run the complete local public-API suite on all five. Run the pinned official corpus on at least Linux amd64 and rerun it on any platform where adapter or semantic results differ. Platform-sensitive multiline-newline cases must execute on Windows and at least one non-Windows target; deterministic encoder goldens remain identical across all five.

Mirror Reference Odin's two principal modes:

- normal tests with `-vet -vet-tabs -strict-style -vet-style -warnings-as-errors -disallow-do`, `ODIN_TEST_FAIL_ON_BAD_MEMORY=true`, and AddressSanitizer where supported;
- the same behavioral suite with `-o:speed` and bad-memory failure enabled.

Run the immutable-registry concurrent-read stress suite under ThreadSanitizer on a supported Linux target, analogous to the race-enabled CI used by mature Go TOML libraries. Issue 14 may stage compile-only checks for Reference Odin's `linux_i386`, `windows_i386`, `linux_riscv64`, and `wasi_wasm32` targets, but they are not package support promises merely because Odin core checks them. Every target ultimately named in release documentation becomes a mandatory compile check or runtime job before that claim ships. The test adapters, Ryu oracle, and fuzz tools are development-only: published `toml` and `temporal` packages must build without C oracle code, Go, Python, Rust, `toml-test`, or another TOML implementation.

### Non-gates and acceptance evidence

Do not invent a line/branch coverage percentage or throughput/latency budget. Surveyed libraries use different coverage policies, and the resolved package contracts establish correctness and cleanup behavior rather than a performance number. Coverage reports and benchmarks are useful implementation evidence and regression signals, but no percentage or benchmark threshold is part of initial design acceptance. Issue 14 may stage benchmark baselining after correctness without turning an unrelated runtime's numbers into a release criterion.

A release-candidate acceptance bundle contains:

- the exact Odin, `toml-test`, and Ryu-oracle pins and acquisition checksums/provenance;
- commands and green logs for normal, speed, sanitizer, race, and target jobs;
- the official JSON conformance report with zero failures/skips;
- deterministic/property seeds and fuzz campaign artifacts;
- allocator/writer ordinal-sweep results;
- no unresolved expected failures, undocumented skips, sanitizer findings, bad-memory reports, or minimized fuzz regressions.

Together these gates prove strict TOML 1.1 conformance, the package's stronger canonical and ownership policies, and the exact public failure behavior. Passing only `toml-test`, achieving a coverage number, or showing a successful happy-path round trip is not acceptance.

# Research: Validation and acceptance precedent for a strict standalone TOML 1.1 implementation

## Summary

Mature TOML libraries consistently gate **official conformance plus focused regression/unit tests**, and several add parse/encode round trips, fuzzing, exact-output goldens, reflection/tag matrices, race checking, feature/compiler-version checks, and multi-OS CI. They do **not** establish widespread precedent for exhaustive allocation-failure injection, allocator provenance/leak accounting, nil-error short-write handling, or this project's exact canonical byte profile; those are justified by the already-resolved Odin ownership/writer/determinism contracts, not by TOML ecosystem convention.

For acceptance, make the pinned official suite a necessary but insufficient gate: `toml-test` v2.2.0 at `ce08da1…`, explicitly selected as TOML 1.1.0, followed by public-API unit/golden/property tests, allocator and writer fault tests, fuzzing, and the supported Odin platform/mode matrix.

## Findings

### 1. Official corpus/version: widespread and mandatory, but pin the exact 1.1 selection

- The official runner calls itself a language-agnostic parser/writer test suite and recommends tagged releases/binaries rather than tracking changing test data. Its versioned runner defaults to TOML **1.0.0**, while the pinned 1.1 manifest is `tests/files-toml-1.1.0`; therefore an acceptance command must say `-toml=1.1.0`, not rely on defaults. [Pinned README](https://github.com/toml-lang/toml-test/blob/ce08da1ddb075d1c7596d663c7fcba9a2ae02c5c/README.md) · [runner implementation](https://github.com/toml-lang/toml-test/blob/ce08da1ddb075d1c7596d663c7fcba9a2ae02c5c/runner.go) · [1.1 manifest](https://github.com/toml-lang/toml-test/blob/ce08da1ddb075d1c7596d663c7fcba9a2ae02c5c/tests/files-toml-1.1.0)
- `toml-rs` declares `+spec-1.1.0` in the crate version and registers separate decoder, encoder, and pretty-encoder compliance binaries backed by `toml-test-harness`/`toml-test-data`. This is direct precedent for testing both directions rather than parser-only acceptance. [toml Cargo.toml](https://github.com/toml-rs/toml/blob/a3d0047c95dfc6e82997d508dd93c9908650a418/crates/toml/Cargo.toml)
- Tomli likewise runs vendored valid and invalid corpus fixtures as ordinary tests, normalizing parsed Python values into the corpus's tagged representation; its claim is all-suite compliance plus 100% branch coverage. [Tomli corpus test](https://github.com/hukkin/tomli/blob/2.4.1/tests/test_data.py) · [README](https://github.com/hukkin/tomli/blob/2.4.1/README.md)

**Acceptance implication:** gate zero valid-decoder, invalid-decoder, and encoder failures and zero undocumented skips. Preserve the runner JSON report. The corpus checks language semantics, not this package's complete API contract: encoder output is reparsed and compared semantically, so it does not prove canonical bytes, allocator behavior, diagnostics, malformed encoder-input rejection, or writer behavior. [encoder comparison](https://github.com/toml-lang/toml-test/blob/ce08da1ddb075d1c7596d663c7fcba9a2ae02c5c/toml.go)

### 2. Focused unit tests, exact goldens, and reflection/tag matrices are as important as conformance

- Pelletier's encoder table covers maps, structs, nested/inline tables, arrays, keys, escapes, numerics, temporals, nil/pointers, embedded fields, custom text marshalers, omit/tag combinations, and option combinations. It compares exact bytes, reparses every successful default output, and verifies every encoder-flag combination remains semantically equivalent. [marshaler_test.go](https://github.com/pelletier/go-toml/blob/b1c03aaa7727837b6996f29e674f5991a13bec1d/marshaler_test.go)
- BurntSushi similarly has broad exact-output encoder tables and focused local-date/time round trips, while its error tests assert detailed parse-error behavior against named invalid fixtures. [encode_test.go](https://github.com/BurntSushi/toml/blob/9594c02aef6f2a81829481af190fea5046f9ca40/encode_test.go) · [error_test.go](https://github.com/BurntSushi/toml/blob/9594c02aef6f2a81829481af190fea5046f9ca40/error_test.go)
- Exact output therefore has broad precedent **where the library promises a spelling**, but this project's particular profile—quoted basic keys, inline-only nested tables, insertion/declaration/sorted-map order, exact float tie rules, and LF policy—is project-specific. It needs byte-for-byte goldens for each rule and repeated-encode tests; passing the official encoder suite cannot substitute.

**Acceptance implication:** require focused matrices for every semantic kind and invalid boundary; duplicate/table-definition states; UTF-8 and escape boundaries; i64/f64 and temporal edges; depth; document insertion order; struct declaration/flattening/tag collisions/`omitempty`; sorted map keys and converted-key collisions; nil/optional/pointer/container state; custom codecs; unknown-field mode; diagnostic category/span/path; and regression fixtures for every bug.

### 3. Round trips/properties and fuzzing are strong precedent, but invariant strength varies

- Pelletier's fuzz target enforces the useful semantic property `decode(x)=v → encode(v)=y → decode(y)=v`, failing if marshal or the second decode fails. [fuzz_test.go](https://github.com/pelletier/go-toml/blob/b1c03aaa7727837b6996f29e674f5991a13bec1d/fuzz_test.go)
- BurntSushi fuzzes accepted parser input through its encoder, but explicitly leaves equality checking as a TODO; its PR CI also runs OSS-Fuzz/CIFuzz for 300 seconds. [fuzz_test.go](https://github.com/BurntSushi/toml/blob/9594c02aef6f2a81829481af190fea5046f9ca40/fuzz_test.go) · [CIFuzz workflow](https://github.com/BurntSushi/toml/blob/9594c02aef6f2a81829481af190fea5046f9ca40/.github/workflows/cifuzz.yml)
- Pelletier likewise runs a 300-second CIFuzz PR job. [CIFuzz workflow](https://github.com/pelletier/go-toml/blob/b1c03aaa7727837b6996f29e674f5991a13bec1d/.github/workflows/cifuzz.yml)

**Acceptance implication:** add (a) generated semantic-tree `encode → parse` identity, modulo canonical NaN metadata; (b) accepted-text `parse → encode → parse` identity; (c) allocated-result versus writer-result byte equality; (d) repeated encoding byte identity; and (e) byte fuzzing including malformed UTF-8, controls/NUL, CR/LF, truncation/EOF, deep nesting, and overflow inputs. Keep a regression corpus for every fuzz discovery. A time-bounded fuzz smoke job is precedent; long-running fuzzing can remain scheduled rather than blocking every local test.

### 4. Writer failures are tested, but this project's exact short-write contract is extra

- Pelletier injects a writer returning an explicit error and requires `Encoder.Encode` to return an error. [broken-writer test](https://github.com/pelletier/go-toml/blob/b1c03aaa7727837b6996f29e674f5991a13bec1d/marshaler_test.go)
- Neither surveyed TOML test suite provides a comprehensive count/error matrix for `io.Writer`. Pelletier's encoder implementation delegates one completed byte buffer to `Write`; the focused test proves explicit-error propagation, not every `(count,error)` combination. [marshaler.go](https://github.com/pelletier/go-toml/blob/b1c03aaa7727837b6996f29e674f5991a13bec1d/marshaler.go)

**Acceptance implication:** explicit writer-error propagation is widespread-enough API hygiene; the following are contract-driven extras and must be locally gated: no writer call before complete preflight, zero calls for empty output, one-use/no-retry semantics, exact propagation when an error accompanies an accepted prefix, rejection of counts outside `0..len`, `.Short_Write` for short count plus nil error, preservation of already accepted canonical prefix, and cleanup on every return.

### 5. Allocation failure/leak tracking is Odin- and contract-driven, not common TOML-library precedent

- Rust, Go, Java, and Python libraries rely primarily on managed/RAII memory and ordinary test tooling; the surveyed suites do not exhaustively fail the Nth allocation and prove rollback at every site.
- Reference Odin exposes a tracking allocator that records live allocations, bad frees, counts, current/peak bytes, and allocation source locations; `core:testing.expect_leaks` lets a test inspect it. [tracking_allocator.odin](https://github.com/odin-lang/Odin/blob/2c25fb92420bfa31da62e2194b0cc2cb8bd54cf8/core/mem/tracking_allocator.odin) · [testing.odin](https://github.com/odin-lang/Odin/blob/2c25fb92420bfa31da62e2194b0cc2cb8bd54cf8/core/testing/testing.odin)
- Odin's own CI runs normal core tests with bad-memory failure enabled and AddressSanitizer on principal desktop platforms. [Odin CI](https://github.com/odin-lang/Odin/blob/2c25fb92420bfa31da62e2194b0cc2cb8bd54cf8/.github/workflows/ci.yml)

**Acceptance implication:** exhaustive successive-allocation failure tests are an appropriate hard gate because the resolved contracts promise transactional parse/clone/set/allocated encode, preflight-before-write, cleanable partial typed-unmarshal installation, exact allocator selection, and no ambient fallback. Run each ownership workflow with default heap, tracking allocator, a fail-after-N allocator until the first success beyond all allocation sites, and a bulk-lifetime arena. Assert zero escaped owners on transactional failure, no bad frees/leaks, unchanged source/table where promised, reachable caller-cleanable typed partial state, and no scratch leaks after writer errors.

### 6. Platform, architecture, compiler/mode matrices are common; scope them to the supported contract

- `toml-rs` runs tests on Linux, Windows, and macOS; tests feature combinations and feature powersets; and separately checks the minimum supported Rust version and minimal dependency versions. [Rust CI](https://github.com/toml-rs/toml/blob/b9e7ad3508c2f891743171eb0fe66a64acea6d85/.github/workflows/ci.yml)
- BurntSushi runs race-enabled tests across Linux/macOS/Windows and old/current supported Go versions. [Go CI](https://github.com/BurntSushi/toml/blob/9594c02aef6f2a81829481af190fea5046f9ca40/.github/workflows/test.yml)
- Tomli spans CPython/PyPy versions, three desktop OSes, arm64/x86_64 wheel builds, and enforces 100% branch coverage independently of the external corpus. [Tomli CI](https://github.com/hukkin/tomli/blob/2.4.1/.github/workflows/tests.yaml)
- Reference Odin's matrix covers macOS Intel/ARM, Linux amd64/ARM, Windows, NetBSD, FreeBSD, emulated Linux riscv64, optimized and normal tests, ASan, and compile checks for i386/WASM/OpenBSD targets. [Odin CI](https://github.com/odin-lang/Odin/blob/2c25fb92420bfa31da62e2194b0cc2cb8bd54cf8/.github/workflows/ci.yml)

**Acceptance implication:** at minimum gate the package on the explicitly supported Odin revision, Linux/macOS/Windows, amd64 plus one non-amd64 target, normal/debug and `-o:speed`, strict vet/style/warnings, and ASan where supported. Add compile-only checks for targets promised by packaging. Full Odin-core OS breadth is precedent for portability testing, not automatically a standalone package requirement; do not claim unsupported targets merely to enlarge CI.

## Recommended acceptance gate

1. **Conformance:** build test-only adapters; run pinned `toml-test` v2.2.0/`ce08da1…` with literal `-toml=1.1.0`; require zero failures/skips and archive JSON.
2. **Focused public API:** parser/semantic/diagnostic fixtures; encoder byte goldens; reflection/tag/container/custom-codec matrices; deterministic-order repetitions.
3. **Properties:** semantic and text round trips, allocated/writer equivalence, canonical re-encode idempotence.
4. **Faults:** fail-after-N allocation sweeps, tracking allocator and arena lifecycle tests, writer count/error matrix, transactional/partial-state assertions.
5. **Robustness:** PR fuzz smoke plus scheduled longer fuzzing; save minimized regressions.
6. **Portability/modes:** supported OS/architecture matrix, normal/debug/speed, strict vet/style/warnings, ASan, and documented compiler revision(s).

## Sources

- Kept: [toml-test v2.2.0 source](https://github.com/toml-lang/toml-test/tree/ce08da1ddb075d1c7596d663c7fcba9a2ae02c5c) — authoritative corpus, version selection, protocols, and comparison behavior.
- Kept: [toml-rs at `a3d0047`](https://github.com/toml-rs/toml/tree/a3d0047c95dfc6e82997d508dd93c9908650a418) and [CI at `b9e7ad3`](https://github.com/toml-rs/toml/blob/b9e7ad3508c2f891743171eb0fe66a64acea6d85/.github/workflows/ci.yml) — TOML 1.1 compliance binaries, unit dependencies, feature/compiler/platform gates.
- Kept: [BurntSushi/toml at `9594c02`](https://github.com/BurntSushi/toml/tree/9594c02aef6f2a81829481af190fea5046f9ca40) — focused encoder/error tests, fuzz target, race/platform CI, and CIFuzz.
- Kept: [pelletier/go-toml at `b1c03aa`](https://github.com/pelletier/go-toml/tree/b1c03aaa7727837b6996f29e674f5991a13bec1d) — unusually broad reflection/tag/output matrix, round-trip fuzz property, broken-writer test, race/platform CI, and CIFuzz.
- Kept: [Tomli 2.4.1 test suite](https://github.com/hukkin/tomli/tree/2.4.1/tests) — independent parser precedent for vendored corpus tests and exhaustive branch coverage; release tag used because search did not expose its peeled commit SHA.
- Kept: [Reference Odin `2c25fb9`](https://github.com/odin-lang/Odin/tree/2c25fb92420bfa31da62e2194b0cc2cb8bd54cf8) — installed primary source for allocator tracking, leak inspection, ASan, modes, and target matrix.
- Dropped: mutable `main`/`master` links, library marketing pages, third-party benchmarks, and TomlJ results — redundant or weaker than the pinned primary sources above.

## Gaps

- No implementation or adapters exist yet, so no corpus pass counts, allocation-site counts, fuzz duration results, or platform results can be reported.
- The Tomli 2.4.1 release tag is version-fixed but not expressed above as a peeled SHA; it is corroborative only and no recommendation depends on it.
- Coverage percentage and performance thresholds are not established by the resolved contracts. Set them only after implementation structure and benchmark baselines exist; do not invent acceptance numbers from unrelated runtimes.

```acceptance-report
{
  "criteriaSatisfied": [
    {
      "id": "criterion-1",
      "status": "satisfied",
      "evidence": "Wrote only the requested validation/acceptance research artifact at the runtime-authoritative output path; no tracker, map, context, or implementation file was edited."
    },
    {
      "id": "criterion-2",
      "status": "satisfied",
      "evidence": "The brief cites pinned primary-source corpus, library test/workflow code, and Reference Odin commit 2c25fb9; it separates widespread precedent from project-contract-specific gates and gives an independently reviewable acceptance checklist."
    }
  ],
  "changedFiles": [
    ".pi-subagents/artifacts/outputs/59fb1025-d213-495d-99df-9ee9105855ac/research.md"
  ],
  "testsAddedOrUpdated": [],
  "commandsRun": [
    {
      "command": "Inspect pinned primary sources for toml-test, toml-rs, BurntSushi/toml, pelletier/go-toml, Tomli, and Reference Odin",
      "result": "passed",
      "summary": "Collected evidence for conformance, unit/golden matrices, round trips, fuzzing, writer failures, allocator tracking, and platform/compiler modes."
    },
    {
      "command": "Read resolved project contracts for conformance, ownership, deterministic encoding, and typed binding",
      "result": "passed",
      "summary": "Used existing decisions only to classify contract-forced extras; tracker and implementation files were not modified."
    },
    {
      "command": "Run TOML implementation tests and toml-test adapters",
      "result": "not-run",
      "summary": "Research-only task; the implementation and adapters do not yet exist."
    }
  ],
  "validationOutput": [
    "Confirmed pinned toml-test v2.2.0 commit and explicit TOML 1.1.0 manifest/version-selection requirement.",
    "Confirmed mature-library precedent for compliance tests, focused exact-output/reflection tests, semantic round trips, fuzzing, and multi-platform/mode CI.",
    "Confirmed Reference Odin supplies tracking allocator/leak inspection and CI bad-memory/ASan gates.",
    "Confirmed exhaustive allocation-failure, nil-error short-write, and exact canonical-byte requirements arise from this project's resolved contracts rather than uniform TOML-library practice."
  ],
  "residualRisks": [
    "No implementation-level pass/fail evidence exists until adapters and package tests are built.",
    "Tomli citations use the fixed 2.4.1 release tag rather than a peeled commit SHA and are corroborative only.",
    "Supported target/compiler policy still needs to be frozen by packaging before the final CI matrix can be exact."
  ],
  "noStagedFiles": true,
  "diffSummary": "Added one evidence-backed Markdown research brief at the authoritative artifact path; no tests or product/tracker files changed.",
  "reviewFindings": [
    "no blockers in the research artifact; implementation acceptance remains contingent on executing the recommended gates"
  ],
  "manualNotes": "The original task mentioned a scratch research destination, but the runtime-authoritative output override was followed exactly. No staging operation was performed."
}
```

# 27 — Platform, sanitizer, race, and bad-memory matrix

**What to build:** Demonstrate that every ownership, concurrency, strictness, and deterministic-output guarantee holds across the complete supported target and execution-mode matrix.

**Blocked by:** 25 — Diagnostic and acceptance-matrix closure; 26 — Typed/codec properties and fuzzing.

**Status:** resolved

- [x] The complete public suite passes on Linux amd64/arm64, macOS amd64/arm64, and Windows amd64 in normal and optimized speed modes.
- [x] Strict vet/style/warnings and bad-memory failure modes are green on their supported jobs.
- [x] AddressSanitizer runs where supported without findings.
- [x] ThreadSanitizer validates frozen-registry concurrent reads on a supported Linux target without races.
- [x] A sanitizer-backed aggregate fuzz campaign runs at least 300 seconds across every required target.
- [x] Reports preserve compiler/target/mode provenance and contain no skips, expected failures, sanitizer findings, race findings, memory reports, or unresolved minimized defects.
- [x] No unapproved architecture or compatibility support is claimed beyond the frozen matrix.

The native CI matrix now executes the complete strict, bad-memory public suite in minimal and speed modes on Linux amd64/arm64, macOS amd64/arm64, and Windows amd64. Each target archives compiler/target/mode provenance, while a 300-second aggregate libFuzzer-plus-AddressSanitizer campaign covers the semantic, typed/codec, and both conformance-adapter entrypoints. A Linux ThreadSanitizer job exercises frozen-registry concurrent reads. The campaign initializes the pinned Odin runtime before each libFuzzer driver, and an invalid-UTF-8 encoder-adapter finding is retained as a focused regression before JSON validation. Local focused sanitizer smoke, final normal/speed suite, and independent standards/spec review pass; the CI matrix supplies the remaining native-target execution evidence.

# 27 — Platform, sanitizer, race, and bad-memory matrix

**What to build:** Demonstrate that every ownership, concurrency, strictness, and deterministic-output guarantee holds across the complete supported target and execution-mode matrix.

**Blocked by:** 25 — Diagnostic and acceptance-matrix closure; 26 — Typed/codec properties and fuzzing.

**Status:** ready-for-agent

- [ ] The complete public suite passes on Linux amd64/arm64, macOS amd64/arm64, and Windows amd64 in normal and optimized speed modes.
- [ ] Strict vet/style/warnings and bad-memory failure modes are green on their supported jobs.
- [ ] AddressSanitizer runs where supported without findings.
- [ ] ThreadSanitizer validates frozen-registry concurrent reads on a supported Linux target without races.
- [ ] A sanitizer-backed aggregate fuzz campaign runs at least 300 seconds across every required target.
- [ ] Reports preserve compiler/target/mode provenance and contain no skips, expected failures, sanitizer findings, race findings, memory reports, or unresolved minimized defects.
- [ ] No unapproved architecture or compatibility support is claimed beyond the frozen matrix.

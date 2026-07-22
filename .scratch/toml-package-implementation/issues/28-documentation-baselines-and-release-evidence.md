# 28 — Documentation, baselines, and release evidence

**What to build:** Publish executable consumer guidance and a reproducible, reviewable release bundle proving the complete TOML 1.1 contract without turning performance observations into premature gates.

**Blocked by:** 27 — Platform, sanitizer, race, and bad-memory matrix.

**Status:** resolved

- [x] Public examples compile and demonstrate parse ownership, mutation, clone/destroy, canonical allocated/writer output, typed marshal/unmarshal, partial cleanup, and codecs.
- [x] Documentation states borrow invalidation, allocator modes, exact cleanup responsibilities, registry concurrency, the package-wide normal-RTTI requirement, support matrix, strictness, semver policy, and non-goals.
- [x] Parse, semantic encode, typed marshal/unmarshal, ordered-table, depth, map-sort, and codec-heavy benchmarks have reproducible commands and recorded non-gating results.
- [x] Inline canonical-profile encoded-size baselines are recorded without pass/fail thresholds.
- [x] The release manifest includes pinned compiler, corpus, oracle, conformance reports, property/fuzz seeds, allocator/writer sweeps, platform/mode jobs, and sanitizer/race evidence.
- [x] A clean checkout reproduces documentation tests and the complete correctness suite.
- [x] The reviewed release bundle contains no unresolved skips, expected failures, sanitizer/race/memory findings, or minimized fuzz defects.

Executable guidance now lives in the three public examples and is enforced in normal and speed modes by `scripts/check_documentation.sh`. The consumer and compatibility guides publish the complete ownership, cleanup, strictness, support, RTTI, SemVer, and non-goal contracts. `scripts/record_benchmarks.py` records all required public-API performance categories and canonical encoded sizes as explicitly non-gating observations. `release/manifest.json` binds the tracked evidence and the complete acceptance-gate source ledger, while the tested fail-closed assembler and dependent CI job require genuine native reports and hash-bound raw logs from the same source revision and CI run for every supported platform, the 300-second AddressSanitizer campaigns, and Linux ThreadSanitizer before producing a SHA-256-indexed `release-bundle`; every unresolved counter must be zero. A clean checkout prepares pinned test dependencies, runs executable documentation, and runs the complete correctness suite with the commands documented in the README.

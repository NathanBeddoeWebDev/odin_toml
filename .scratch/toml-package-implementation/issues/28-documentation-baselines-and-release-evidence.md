# 28 — Documentation, baselines, and release evidence

**What to build:** Publish executable consumer guidance and a reproducible, reviewable release bundle proving the complete TOML 1.1 contract without turning performance observations into premature gates.

**Blocked by:** 27 — Platform, sanitizer, race, and bad-memory matrix.

**Status:** ready-for-agent

- [ ] Public examples compile and demonstrate parse ownership, mutation, clone/destroy, canonical allocated/writer output, typed marshal/unmarshal, partial cleanup, and codecs.
- [ ] Documentation states borrow invalidation, allocator modes, exact cleanup responsibilities, registry concurrency, RTTI-disabled behavior, support matrix, strictness, semver policy, and non-goals.
- [ ] Parse, semantic encode, typed marshal/unmarshal, ordered-table, depth, map-sort, and codec-heavy benchmarks have reproducible commands and recorded non-gating results.
- [ ] Inline canonical-profile encoded-size baselines are recorded without pass/fail thresholds.
- [ ] The release manifest includes pinned compiler, corpus, oracle, conformance reports, property/fuzz seeds, allocator/writer sweeps, platform/mode jobs, and sanitizer/race evidence.
- [ ] A clean checkout reproduces documentation tests and the complete correctness suite.
- [ ] The reviewed release bundle contains no unresolved skips, expected failures, sanitizer/race/memory findings, or minimized fuzz defects.

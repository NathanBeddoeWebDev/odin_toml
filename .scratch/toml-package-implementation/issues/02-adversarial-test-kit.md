# 02 — Adversarial test kit

**What to build:** Provide verified test-only allocators, writers, and deterministic replay helpers that can observe every ownership, allocation, writer, and randomized behavior promised by the public packages.

**Blocked by:** 01 — Reproducible scaffold and frozen declarations.

**Status:** ready-for-agent

- [ ] Tracking and fail-at-N allocators account for allocation, nonzero allocation, resize, nonzero resize, release, and foreign-release attempts by ordinal.
- [ ] A rejecting ambient allocator proves that tested package operations use only their selected allocator.
- [ ] Feature-reporting and unsupported-mode external-lifetime allocators model logical destruction without unsupported individual frees.
- [ ] A scripted writer can produce every valid and invalid byte-count/error combination and records each call exactly once.
- [ ] Deterministic random helpers report replayable seeds and reproduce generated sequences exactly.
- [ ] The support utilities pass focused self-tests and remain test-only rather than expanding either public package.

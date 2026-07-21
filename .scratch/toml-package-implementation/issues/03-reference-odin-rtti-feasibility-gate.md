# 03 — Reference-Odin RTTI feasibility gate

**What to build:** Prove on the pinned compiler that the approved typed-binding behavior can be implemented safely and exactly before reflection-dependent features begin.

**Blocked by:** 01 — Reproducible scaffold and frozen declarations.

**Status:** blocked-design-review — Reference Odin cannot compile the frozen package for a semantic consumer with `-no-rtti`; see [design review 001](../../../design-reviews/001-reference-odin-no-rtti.md).

- [x] Compile/run probes demonstrate declaration-order field and tag enumeration, anonymous `using` handling, and destination-backed `any` access.
- [x] Probes demonstrate exact named/distinct type handling, exact `typeid` lookup, optional-union inspection, and wrapper destination access.
- [x] Probes demonstrate allocator-controlled map and dynamic-array installation and aligned allocation for zero-size pointees.
- [ ] Semantic workflows remain available without RTTI and typed entry points expose the documented unavailable capability. **Blocked:** the pinned compiler rejects the frozen typed `any` declarations while checking the external semantic consumer.
- [x] A [checked matrix](../../../design-reviews/rtti-feasibility-matrix.md) maps every approved typed feature to a proven compiler/runtime mechanism.
- [x] The missing capability has stopped reflection-dependent work and returned the contract to design review without narrowing it.

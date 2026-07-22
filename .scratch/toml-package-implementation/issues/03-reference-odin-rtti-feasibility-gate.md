# 03 — Reference-Odin RTTI feasibility gate

**What to build:** Prove on the pinned compiler that the approved typed-binding behavior can be implemented safely and exactly before reflection-dependent features begin.

**Blocked by:** 01 — Reproducible scaffold and frozen declarations.

**Status:** resolved — the approved contract now requires normal RTTI for the complete package; see [design review 001](../../../design-reviews/001-reference-odin-no-rtti.md).

- [x] Compile/run probes demonstrate declaration-order field and tag enumeration, anonymous `using` handling, and destination-backed `any` access.
- [x] Probes demonstrate exact named/distinct type handling, exact `typeid` lookup, optional-union inspection, and wrapper destination access.
- [x] Probes demonstrate allocator-controlled map and dynamic-array installation and aligned allocation for zero-size pointees.
- [x] The package-wide normal-RTTI requirement is explicit; semantic-only `ODIN_NO_RTTI` builds are no longer supported.
- [x] A [checked matrix](../../../design-reviews/rtti-feasibility-matrix.md) maps every approved typed feature to a proven compiler/runtime mechanism.
- [x] The missing capability stopped reflection-dependent work until design review explicitly removed RTTI-disabled support from the approved contract.

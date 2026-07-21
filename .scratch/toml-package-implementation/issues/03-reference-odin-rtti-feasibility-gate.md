# 03 — Reference-Odin RTTI feasibility gate

**What to build:** Prove on the pinned compiler that the approved typed-binding behavior can be implemented safely and exactly before reflection-dependent features begin.

**Blocked by:** 01 — Reproducible scaffold and frozen declarations.

**Status:** ready-for-agent

- [ ] Compile/run probes demonstrate declaration-order field and tag enumeration, anonymous `using` handling, and destination-backed `any` access.
- [ ] Probes demonstrate exact named/distinct type handling, exact `typeid` lookup, optional-union inspection, and wrapper destination access.
- [ ] Probes demonstrate allocator-controlled map and dynamic-array installation and aligned allocation for zero-size pointees.
- [ ] Semantic workflows remain available without RTTI and typed entry points expose the documented unavailable capability.
- [ ] A checked matrix maps every approved typed feature to a proven compiler/runtime mechanism.
- [ ] Any missing capability stops dependent work and returns the design for review; the approved contract is not silently narrowed.

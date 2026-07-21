# 10 — Codec registry lifecycle

**What to build:** Deliver caller-owned, allocator-explicit, exact-type directional codec registration that can be safely frozen and shared across concurrent read-only calls.

**Blocked by:** 03 — Reference-Odin RTTI feasibility gate; 07 — Allocator capability gate.

**Status:** ready-for-agent

- [ ] Registry initialization retains the selected allocator and produces the exact documented initialized state.
- [ ] Marshal and unmarshal callbacks can be registered independently for one exact `typeid` with their raw user-data pointers.
- [ ] Duplicate registration is rejected only in the duplicated direction; invalid allocators, registries, type IDs, and callbacks report exact errors.
- [ ] Registry growth failure preserves every previously registered entry and leaks no storage.
- [ ] Destruction releases or logically ends registry storage, zeros the registry, and handles repeated cleanup safely.
- [ ] Frozen concurrent reads are race-free while mutation or destruction during active calls remains a documented caller violation.
- [ ] The registry never owns callbacks or user data and introduces no package-global mutable state.

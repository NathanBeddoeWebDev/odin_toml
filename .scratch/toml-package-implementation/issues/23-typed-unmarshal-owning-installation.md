# 23 — Typed unmarshal owning installation

**What to build:** Install all approved owning container and wrapper destinations in documented ownership-safe commit units, including partial allocation failure that callers can clean safely.

**Blocked by:** 07 — Allocator capability gate; 20 — Typed marshal: containers, maps, and wrappers; 22 — Typed unmarshal immutable preflight.

**Status:** ready-for-agent

- [ ] Fixed/enumerated arrays require exact length while slices and dynamic arrays install storage before elements.
- [ ] Maps require nil state and commit complete key/value pairs in semantic insertion order.
- [ ] Pointers require clean nil slots, including aligned sentinel allocation for zero-size pointees.
- [ ] Optional unions activate their sole non-nil alternative for present TOML and never synthesize nil.
- [ ] Matched strings and every owning child are cloned into the selected allocator; checked depth and size apply before installation.
- [ ] Preflight allocation failures leave the complete destination unchanged.
- [ ] Every installation allocation ordinal leaves only earlier ownership-safe committed units, cleans uninstalled package state, and preserves exact allocator errors.
- [ ] A two-allocator provenance test proves missing and ignored owning fields remain untouched and neither allocator receives a foreign free.
- [ ] Executable cleanup examples cover a wholly zero-start destination and partial installation for both individually freeing and external-lifetime allocators.

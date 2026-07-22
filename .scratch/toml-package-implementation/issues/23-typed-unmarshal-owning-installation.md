# 23 — Typed unmarshal owning installation

**What to build:** Install all approved owning container and wrapper destinations in documented ownership-safe commit units, including partial allocation failure that callers can clean safely.

**Blocked by:** 07 — Allocator capability gate; 20 — Typed marshal: containers, maps, and wrappers; 22 — Typed unmarshal immutable preflight.

**Status:** resolved

- [x] Fixed/enumerated arrays require exact length while slices and dynamic arrays install storage before elements.
- [x] Maps require nil state and commit complete key/value pairs in semantic insertion order.
- [x] Pointers require clean nil slots, including aligned sentinel allocation for zero-size pointees.
- [x] Optional unions activate their sole non-nil alternative for present TOML and never synthesize nil.
- [x] Matched strings and every owning child are cloned into the selected allocator; checked depth and size apply before installation.
- [x] Preflight allocation failures leave the complete destination unchanged.
- [x] Every installation allocation ordinal leaves only earlier ownership-safe committed units, cleans uninstalled package state, and preserves exact allocator errors.
- [x] A two-allocator provenance test proves missing and ignored owning fields remain untouched and neither allocator receives a foreign free.
- [x] Executable cleanup examples cover a wholly zero-start destination and partial installation for both individually freeing and external-lifetime allocators.

Typed unmarshal now recursively preflights and installs owning strings, fixed and allocated sequences, maps, pointers, and tagged or pure-maybe optional unions, including map and wrapper roots. Map storage is capacity-planned before installation, pair values remain package-owned until complete insertion, zero-size pointees receive aligned sentinels, and every failure leaves only caller-reachable commit units. Public-seam tests sweep allocation ordinals, verify map-prefix order, allocator provenance, empty and zero-size containers, root wrappers, and external-lifetime logical cleanup. The typed cleanup contract and executable complete/partial examples are documented in the README.

# 24 — Custom unmarshal codecs

**What to build:** Bind exact application types through caller callbacks while keeping semantic borrows temporary, destination slots transactional, and ownership explicit.

**Blocked by:** 10 — Codec registry lifecycle; 21 — Custom marshal codecs; 23 — Typed unmarshal owning installation.

**Status:** resolved

**Approved map commit clarification:** [Design review 002](../../../design-reviews/002-custom-unmarshal-map-commit-boundary.md) resolves the conflict between complete generic map-pair staging and immediate opaque callback ownership. A staged map entry remains removable until complete unless a nested custom unmarshaler succeeds; that first success commits the containing entry, which may remain recursively cleanable and partial after a later failure while the failing callback slot is exact zero.

- [x] Exact codec lookup precedes named-type, temporal, generic, and wrapper handling and remains excluded from map-key conversion.
- [x] The callback receives the exact clean destination slot, borrowed ranged semantic value, user data, selected allocator, and caller location.
- [x] Success transfers installed ownership to the application under the documented typed cleanup rules.
- [x] Any callback failure restores its entire supplied destination slot to exact zero; only earlier independent commit units may remain.
- [x] Nonzero application codes and exact allocator errors remain distinct and include frozen path/range/type payloads.
- [x] Wrapper precedence, user data, callback order, paired directional codecs, and concurrent frozen-registry calls are covered.
- [x] Callbacks cannot retain semantic borrows, mutate sources, or re-enter active typed TOML operations.
- [x] Fail-at-N tests prove transactional callback slots and complete cleanup of every package-owned temporary.

Typed unmarshal now performs exact directional codec lookup during immutable preflight and ordered installation, passes the frozen callback contract, zeros every failing callback slot, and preserves exact codec diagnostics or allocator errors. Map installation preallocates and stages all owned keys before invoking callbacks so final value slots do not move; generic failures remove incomplete entries, while a first nested opaque success commits its recursively cleanable containing entry. Public-seam tests cover exact and wrapper precedence, temporal overrides, root codecs, map-key exclusion, ownership/error boundaries, allocator sweeps, semantic order, paired directions, and concurrent frozen-registry reads. The README records callback borrow, re-entry, transactional-slot, and map cleanup obligations.

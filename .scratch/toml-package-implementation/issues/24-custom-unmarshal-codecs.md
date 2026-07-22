# 24 — Custom unmarshal codecs

**What to build:** Bind exact application types through caller callbacks while keeping semantic borrows temporary, destination slots transactional, and ownership explicit.

**Blocked by:** 10 — Codec registry lifecycle; 21 — Custom marshal codecs; 23 — Typed unmarshal owning installation.

**Status:** ready-for-agent

**Approved map commit clarification:** [Design review 002](../../../design-reviews/002-custom-unmarshal-map-commit-boundary.md) resolves the conflict between complete generic map-pair staging and immediate opaque callback ownership. A staged map entry remains removable until complete unless a nested custom unmarshaler succeeds; that first success commits the containing entry, which may remain recursively cleanable and partial after a later failure while the failing callback slot is exact zero.

- [ ] Exact codec lookup precedes named-type, temporal, generic, and wrapper handling and remains excluded from map-key conversion.
- [ ] The callback receives the exact clean destination slot, borrowed ranged semantic value, user data, selected allocator, and caller location.
- [ ] Success transfers installed ownership to the application under the documented typed cleanup rules.
- [ ] Any callback failure restores its entire supplied destination slot to exact zero; only earlier independent commit units may remain.
- [ ] Nonzero application codes and exact allocator errors remain distinct and include frozen path/range/type payloads.
- [ ] Wrapper precedence, user data, callback order, paired directional codecs, and concurrent frozen-registry calls are covered.
- [ ] Callbacks cannot retain semantic borrows, mutate sources, or re-enter active typed TOML operations.
- [ ] Fail-at-N tests prove transactional callback slots and complete cleanup of every package-owned temporary.

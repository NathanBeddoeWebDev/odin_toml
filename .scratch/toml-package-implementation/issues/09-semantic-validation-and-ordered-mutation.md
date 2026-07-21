# 09 — Semantic validation and ordered mutation

**What to build:** Let callers safely mutate insertion-ordered semantic tables while rejecting malformed ownership graphs at public lifecycle and mutation boundaries.

**Blocked by:** 02 — Adversarial test kit; 08 — Semantic owner lifecycle.

**Status:** resolved

- [x] Validation detects invalid text, temporals, containers, duplicate keys, cycles, aliases, allocator mismatches, and excessive local depth with exact structured errors.
- [x] `set` deep-clones caller input through the table owner and never aliases caller ownership.
- [x] Replacement preserves entry position; new insertion appends; removal destroys the removed owner and stably compacts entries.
- [x] Failed insertion or replacement leaves the table physically and semantically unchanged and cleans all temporary ownership.
- [x] Local depth 256 succeeds and 257 fails before commit; a locally valid nested mutation may still be rejected by a later stricter root-relative operation.
- [x] Structural mutation invalidates documented borrows and remove/reinsert produces append order.
- [x] Allocation-ordinal sweeps, rejecting ambient allocation, and malformed caller values exercise all public mutation results.

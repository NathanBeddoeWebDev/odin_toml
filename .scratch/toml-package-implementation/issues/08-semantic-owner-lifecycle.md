# 08 — Semantic owner lifecycle

**What to build:** Deliver initialized allocator-owned semantic documents and independent deep lifecycle operations with predictable borrowing and cleanup.

**Blocked by:** 04 — Complete temporal package; 07 — Allocator capability gate.

**Status:** ready-for-agent

- [ ] Empty, whitespace-only, and comment-only byte and string documents produce initialized empty owners distinct from zero documents.
- [ ] `get` performs allocation-free borrowed lookup without transferring ownership.
- [ ] Document and standalone-value clones are deep, independent, preserve semantic order, and use only the selected allocator.
- [ ] Clone failure returns a zero result, leaves the source unchanged, and cleans every partial allocation.
- [ ] Document and standalone-value destruction end descendant ownership, zero the supplied owner, and are idempotent.
- [ ] Every semantic value alternative, empty container, retained allocator, external-lifetime allocator, and nil-allocator error is covered.
- [ ] Executable public examples demonstrate owner versus borrowed-alias behavior and the applicable cleanup operation.

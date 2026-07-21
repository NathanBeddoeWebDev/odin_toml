# 08 — Semantic owner lifecycle

**What to build:** Deliver initialized allocator-owned semantic documents and independent deep lifecycle operations with predictable borrowing and cleanup.

**Blocked by:** 04 — Complete temporal package; 07 — Allocator capability gate.

**Status:** resolved

- [x] Empty, whitespace-only, and comment-only byte and string documents produce initialized empty owners distinct from zero documents.
- [x] `get` performs allocation-free borrowed lookup without transferring ownership.
- [x] Document and standalone-value clones are deep, independent, preserve semantic order, and use only the selected allocator.
- [x] Clone failure returns a zero result, leaves the source unchanged, and cleans every partial allocation.
- [x] Document and standalone-value destruction end descendant ownership, zero the supplied owner, and are idempotent.
- [x] Every semantic value alternative, empty container, retained allocator, external-lifetime allocator, and nil-allocator error is covered.
- [x] Executable public examples demonstrate owner versus borrowed-alias behavior and the applicable cleanup operation.

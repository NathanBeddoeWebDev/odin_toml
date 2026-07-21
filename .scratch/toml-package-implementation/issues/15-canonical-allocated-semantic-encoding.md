# 15 — Canonical allocated semantic encoding

**What to build:** Serialize complete owned semantic documents to exact deterministic TOML bytes using the single approved canonical profile and complete preflight validation.

**Blocked by:** 04 — Complete temporal package; 06 — Canonical binary64-format gate; 09 — Semantic validation and ordered mutation.

**Status:** resolved

- [x] Empty documents return nil-backed zero-length output with no allocation.
- [x] Every root entry is a quoted-key assignment followed by LF; nested tables are inline and arrays use the fixed spacing rules.
- [x] Keys, strings, integers, floats, booleans, and all temporal kinds use their exact canonical spellings.
- [x] Traversal follows semantic table insertion order and array order and emits no comments, headers, dotted keys, indentation, blank lines, or platform newlines.
- [x] Complete preflight rejects invalid text, temporals, containers, duplicates, cycles, aliases, allocator mismatch, depth, and checked-size failures before result ownership escapes.
- [x] Successful nonempty output owns exactly its returned length; every allocation failure returns empty output and cleans scratch state.
- [x] Exact-byte goldens and float-oracle checks are stable across repeated runs and supported platforms.
- [x] Parsing canonical output reproduces the represented semantic value where the strict parser supports it.

Canonical allocated semantic encoding now uses one checked sizing/emission plan after complete semantic preflight, returns exact-length caller-owned output, and keeps empty output allocation-free even when the root retains capacity. Focused tests cover canonical bytes, temporal and binary64 spellings, semantic round trips including NaN normalization, depth and malformed-owner diagnostics, exhaustive allocation failures, and both external-lifetime allocator branches. The pinned full suite and cross-target checks pass.

# 15 — Canonical allocated semantic encoding

**What to build:** Serialize complete owned semantic documents to exact deterministic TOML bytes using the single approved canonical profile and complete preflight validation.

**Blocked by:** 04 — Complete temporal package; 06 — Canonical binary64-format gate; 09 — Semantic validation and ordered mutation.

**Status:** ready-for-agent

- [ ] Empty documents return nil-backed zero-length output with no allocation.
- [ ] Every root entry is a quoted-key assignment followed by LF; nested tables are inline and arrays use the fixed spacing rules.
- [ ] Keys, strings, integers, floats, booleans, and all temporal kinds use their exact canonical spellings.
- [ ] Traversal follows semantic table insertion order and array order and emits no comments, headers, dotted keys, indentation, blank lines, or platform newlines.
- [ ] Complete preflight rejects invalid text, temporals, containers, duplicates, cycles, aliases, allocator mismatch, depth, and checked-size failures before result ownership escapes.
- [ ] Successful nonempty output owns exactly its returned length; every allocation failure returns empty output and cleans scratch state.
- [ ] Exact-byte goldens and float-oracle checks are stable across repeated runs and supported platforms.
- [ ] Parsing canonical output reproduces the represented semantic value where the strict parser supports it.

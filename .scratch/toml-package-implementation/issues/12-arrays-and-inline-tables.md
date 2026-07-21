# 12 — Arrays and inline tables

**What to build:** Extend complete-document parsing to ordered heterogeneous arrays and sealed inline tables without relaxing strict TOML grammar or ownership guarantees.

**Blocked by:** 11 — Strict scalar-document parsing.

**Status:** ready-for-agent

- [ ] Arrays preserve order, allow every TOML value kind, and support valid nesting and multiline trivia.
- [ ] Invalid separators, comments, trailing syntax, and malformed child values report exact ranges and categories.
- [ ] Inline tables preserve decoded insertion order and cannot be extended after their closing delimiter.
- [ ] Dotted paths local to an inline table remain isolated from surrounding table-definition state.
- [ ] Depth uses semantic key/index path length, applies zero/default/explicit limits exactly, and rejects a child before allocating it.
- [ ] Successful trees own every child through the document allocator and retain no syntax provenance.
- [ ] Fail-at-N tests enter every container allocation and append phase and prove zero-result cleanup.

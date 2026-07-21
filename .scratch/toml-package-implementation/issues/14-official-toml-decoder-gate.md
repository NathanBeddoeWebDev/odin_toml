# 14 — Official TOML decoder gate

**What to build:** Verify the completed strict parser against the pinned official TOML 1.1 decoder corpus through a test-only adapter that uses only public package operations.

**Blocked by:** 13 — Stateful tables and arrays of tables.

**Status:** ready-for-agent

- [ ] The decoder adapter translates public semantic results into the corpus protocol without importing private parser state.
- [ ] Malformed adapter input and unsupported protocol values are covered by focused negative tests.
- [ ] The official tool is built from the complete pinned source revision with license and provenance recorded.
- [ ] The runner selects literal TOML version 1.1.0 and cannot silently drift to another version.
- [ ] The preserved machine-readable report contains zero valid-decoder failures, zero invalid-decoder failures, and zero skips.
- [ ] Any discovered defect becomes a focused public-API regression before this ticket closes.

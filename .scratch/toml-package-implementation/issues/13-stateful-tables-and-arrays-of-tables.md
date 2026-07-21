# 13 — Stateful tables and arrays of tables

**What to build:** Complete strict TOML table-definition semantics, including decoded dotted paths, standard headers, and nested arrays of tables attached to the latest applicable parent.

**Blocked by:** 12 — Arrays and inline tables.

**Status:** ready-for-agent

- [ ] Dotted keys create legal implicit parents and detect duplicates after exact decoded-path resolution.
- [ ] Standard headers permit legal late implicit-parent definition and reject repeated headers, dotted-defined restrictions, and scalar/table conflicts.
- [ ] Inline-sealed, static-array, table, and array-of-tables transitions follow the frozen state matrix.
- [ ] Repeated array-of-table headers append elements and nested child headers attach to the latest applicable parent element.
- [ ] Quoted dots, case differences, and Unicode normalization differences remain exact key data rather than path aliases.
- [ ] Definition errors include exact current and related prior-definition ranges.
- [ ] Stable semantic/definition identity survives fallible storage growth without retaining unsafe pointers.
- [ ] Every permitted and forbidden transition has adjacent public parse fixtures and allocation-failure coverage.

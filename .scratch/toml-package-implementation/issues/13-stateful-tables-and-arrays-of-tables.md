# 13 — Stateful tables and arrays of tables

**What to build:** Complete strict TOML table-definition semantics, including decoded dotted paths, standard headers, and nested arrays of tables attached to the latest applicable parent.

**Blocked by:** 12 — Arrays and inline tables.

**Status:** resolved

- [x] Dotted keys create legal implicit parents and detect duplicates after exact decoded-path resolution.
- [x] Standard headers permit legal late implicit-parent definition and reject repeated headers, dotted-defined restrictions, and scalar/table conflicts.
- [x] Inline-sealed, static-array, table, and array-of-tables transitions follow the frozen state matrix.
- [x] Repeated array-of-table headers append elements and nested child headers attach to the latest applicable parent element.
- [x] Quoted dots, case differences, and Unicode normalization differences remain exact key data rather than path aliases.
- [x] Definition errors include exact current and related prior-definition ranges.
- [x] Stable semantic/definition identity survives fallible storage growth without retaining unsafe pointers.
- [x] Every permitted and forbidden transition has adjacent public parse fixtures and allocation-failure coverage.

# 19 — Typed marshal: roots, scalars, and struct projection

**What to build:** Marshal eligible application structs through reflection into the same canonical bytes as equivalent semantic documents.

**Blocked by:** 03 — Reference-Odin RTTI feasibility gate; 16 — Semantic writer encoding.

**Status:** ready-for-agent

- [ ] Eligible typed roots are table-shaped structs; unsupported scalar, temporal, sequence, nil, and other root shapes fail explicitly.
- [ ] Strings, booleans, signed/unsigned integers, floats, named forms, and exact temporal types use closed same-category checked mapping.
- [ ] Fields use exact names or valid `toml` renames and preserve declaration and flatten-expansion order.
- [ ] Anonymous `using` structs flatten under the approved rules while named `using` fields remain named.
- [ ] The complete tag list is validated before data traversal; malformed tags and effective-name collisions report exact errors.
- [ ] Ignored fields are never inspected, and `omitempty` uses only the frozen finite set of empty states.
- [ ] Allocated marshal bytes match semantic unparse bytes for equivalent represented values.
- [ ] Writer marshal performs full preflight and satisfies the common writer identity and fault contract for this supported slice.

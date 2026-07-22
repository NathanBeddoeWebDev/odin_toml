# 19 — Typed marshal: roots, scalars, and struct projection

**What to build:** Marshal eligible application structs through reflection into the same canonical bytes as equivalent semantic documents.

**Blocked by:** 03 — Reference-Odin RTTI feasibility gate; 16 — Semantic writer encoding.

**Status:** resolved

- [x] Eligible typed roots are table-shaped structs; unsupported scalar, temporal, sequence, nil, and other root shapes fail explicitly.
- [x] Strings, booleans, signed/unsigned integers, floats, named forms, and exact temporal types use closed same-category checked mapping.
- [x] Fields use exact names or valid `toml` renames and preserve declaration and flatten-expansion order.
- [x] Anonymous `using` structs flatten under the approved rules while named `using` fields remain named.
- [x] The complete tag list is validated before data traversal; malformed tags and effective-name collisions report exact errors.
- [x] Ignored fields are never inspected, and `omitempty` uses only the frozen finite set of empty states.
- [x] Allocated marshal bytes match semantic unparse bytes for equivalent represented values.
- [x] Writer marshal performs full preflight and satisfies the common writer identity and fault contract for this supported slice.

Typed marshal now builds a reduced reflected struct plan, projects selected values into allocator-owned semantic scratch, and retains the shared canonical sizing/emission plan through allocated or writer output. Public-seam tests cover scalar and temporal equivalence, root/type/range/text/depth diagnostics, tag grammar and collisions, flattening/order/omission, allocator-failure cleanup, writer preflight, byte identity, and writer fault precedence. Custom codecs, containers, maps, and wrappers remain assigned to issues 20–21.

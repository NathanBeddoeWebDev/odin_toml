# 20 — Typed marshal: containers, maps, and wrappers

**What to build:** Extend typed marshal to the approved application containers and wrappers while preserving deterministic ordering, closed type behavior, and recursion safety.

**Blocked by:** 19 — Typed marshal: roots, scalars, and struct projection.

**Status:** ready-for-agent

- [ ] Fixed/enumerated arrays, slices, and dynamic arrays preserve element order and validate their declared element type even when empty.
- [ ] Eligible maps accept only string or named/distinct string keys, sort converted keys by unsigned UTF-8 bytes, and reject conversion collisions.
- [ ] Ordinary pointers and optional unions follow exact nil, omission, and active-alternative rules.
- [ ] Non-nil `any` values unwrap recursively; generic unsupported and nil states fail explicitly.
- [ ] Repeated acyclic references encode by value while active recursion cycles produce structured errors.
- [ ] Numeric range, depth, size, map, wrapper, and source-type diagnostics carry the frozen path/type/count payloads.
- [ ] Allocated and writer forms remain byte-identical and fail-at-N/writer sweeps leak no package state or emit before preflight.

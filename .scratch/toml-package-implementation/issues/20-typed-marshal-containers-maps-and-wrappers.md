# 20 — Typed marshal: containers, maps, and wrappers

**What to build:** Extend typed marshal to the approved application containers and wrappers while preserving deterministic ordering, closed type behavior, and recursion safety.

**Blocked by:** 19 — Typed marshal: roots, scalars, and struct projection.

**Status:** resolved

- [x] Fixed/enumerated arrays, slices, and dynamic arrays preserve element order and validate their declared element type even when empty.
- [x] Eligible maps accept only string or named/distinct string keys, sort converted keys by unsigned UTF-8 bytes, and reject conversion collisions.
- [x] Ordinary pointers and optional unions follow exact nil, omission, and active-alternative rules.
- [x] Non-nil `any` values unwrap recursively; generic unsupported and nil states fail explicitly.
- [x] Repeated acyclic references encode by value while active recursion cycles produce structured errors.
- [x] Numeric range, depth, size, map, wrapper, and source-type diagnostics carry the frozen path/type/count payloads.
- [x] Allocated and writer forms remain byte-identical and fail-at-N/writer sweeps leak no package state or emit before preflight.

Typed marshal now projects the approved sequence, map, pointer, optional-union, and `any` forms into allocator-owned semantic scratch before canonical emission. Map plans convert, validate, collision-check, and unsigned-byte-sort keys before value traversal; active view-aware reference tracking rejects only live recursion cycles. Public-seam tests cover empty declared-type validation, zero-sized containers, deterministic map diagnostics, nil and omission rules, nested/root wrappers, repeated aliases and cycles, exact paths/types, allocated/writer identity, writer preflight, and allocator failure cleanup.

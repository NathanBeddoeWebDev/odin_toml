# 25 — Diagnostic and acceptance-matrix closure

**What to build:** Close every frozen public diagnostic and failure-contract gap with structured public-seam tests rather than relying on message text or private implementation coverage.

**Blocked by:** 16 — Semantic writer encoding; 24 — Custom unmarshal codecs.

**Status:** resolved

- [x] A maintained ledger maps every reachable public error alternative and detail category to at least one public test.
- [x] Configuration, lexical, grammar, scalar, definition, data, depth/size, type, tag, field, map, codec, allocator, and writer precedence is tested exactly.
- [x] Unused diagnostic fields remain zero and all applicable source/destination/related types, value kinds, counts, ranges, definitions, paths, and external errors are asserted structurally.
- [x] Coordinate cases include ASCII, multibyte Unicode, TAB, LF, CRLF, malformed UTF-8, decoded/source width differences, related definitions, and EOF ranges.
- [x] Long keys and deep paths preserve UTF-8-safe first/last snapshots and exact omission metadata.
- [x] Parse/unmarshal diagnostics outlive input; encode diagnostics obey their documented source borrow lifetimes.
- [x] Options, nil-success states, required result consumption, and every allocator/writer/codec external error remain exact.
- [x] Any genuinely inapplicable declaration alternative is explicitly justified rather than silently skipped.

The public diagnostic acceptance ledger now checks 183 declaration members and 18 cross-cutting contracts against named public-seam tests. Focused fixtures close exact grammar sets, wrapped temporal sub-errors, source coordinates and lifetimes, UTF-8-safe long-key snapshots, first-eight/final-24 deep paths, complete typed payload fields, codec codes, registry/configuration precedence, allocator and writer propagation, and encode-path borrow identity. Six declaration members are retained with explicit construction-based inapplicability proofs rather than silent skips. The pinned focused suites, full normal/speed/platform/conformance checks, and independent standards/spec reviews pass.

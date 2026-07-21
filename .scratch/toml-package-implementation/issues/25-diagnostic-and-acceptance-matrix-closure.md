# 25 — Diagnostic and acceptance-matrix closure

**What to build:** Close every frozen public diagnostic and failure-contract gap with structured public-seam tests rather than relying on message text or private implementation coverage.

**Blocked by:** 16 — Semantic writer encoding; 24 — Custom unmarshal codecs.

**Status:** ready-for-agent

- [ ] A maintained ledger maps every reachable public error alternative and detail category to at least one public test.
- [ ] Configuration, lexical, grammar, scalar, definition, data, depth/size, type, tag, field, map, codec, allocator, and writer precedence is tested exactly.
- [ ] Unused diagnostic fields remain zero and all applicable source/destination/related types, value kinds, counts, ranges, definitions, paths, and external errors are asserted structurally.
- [ ] Coordinate cases include ASCII, multibyte Unicode, TAB, LF, CRLF, malformed UTF-8, decoded/source width differences, related definitions, and EOF ranges.
- [ ] Long keys and deep paths preserve UTF-8-safe first/last snapshots and exact omission metadata.
- [ ] Parse/unmarshal diagnostics outlive input; encode diagnostics obey their documented source borrow lifetimes.
- [ ] Options, nil-success states, required result consumption, and every allocator/writer/codec external error remain exact.
- [ ] Any genuinely inapplicable declaration alternative is explicitly justified rather than silently skipped.

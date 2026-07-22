# 21 — Custom marshal codecs

**What to build:** Allow callers to opt exact application types into semantic-value marshal callbacks without bypassing canonical validation, ownership, or deterministic output.

**Blocked by:** 10 — Codec registry lifecycle; 16 — Semantic writer encoding; 20 — Typed marshal: containers, maps, and wrappers.

**Status:** resolved

- [x] Exact codec lookup precedes named-type, temporal, generic, and wrapper handling at each typed node.
- [x] `omitempty` is evaluated before lookup and map keys never consult codecs.
- [x] Each encountered node invokes its marshaler exactly once during preflight and reuses the cached semantic value during emission.
- [x] Callback user data and selected allocator are delivered exactly; nonzero callback codes and allocator failures remain distinct.
- [x] Successful callback values are validated for text, temporal, container, duplicate, cycle, alias, allocator, depth, and size invariants.
- [x] The package destroys every successful callback value exactly once on success or any later allocation/writer/error path.
- [x] Allocated and writer output remains canonical and byte-identical, including concurrent calls through a frozen registry.
- [x] Callback re-entry and source mutation/borrow retention remain prohibited and are documented at the public seam.

Typed marshal now resolves exact frozen-registry entries at every eligible source node, validates and caches each successful semantic result, emits only through the canonical semantic plan, and retains a complete allocator-aware ownership ledger for exact-once cleanup across malformed values and every later failure. Public-seam tests cover named/temporal/wrapper precedence, omission and map-key exclusion, sorted callback order, root tables, exact callback payloads and errors, semantic invariants, cross-result aliases, fail-at-N cleanup, writer identity/faults, and concurrent frozen-registry calls.

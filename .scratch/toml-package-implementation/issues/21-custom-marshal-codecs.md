# 21 — Custom marshal codecs

**What to build:** Allow callers to opt exact application types into semantic-value marshal callbacks without bypassing canonical validation, ownership, or deterministic output.

**Blocked by:** 10 — Codec registry lifecycle; 16 — Semantic writer encoding; 20 — Typed marshal: containers, maps, and wrappers.

**Status:** ready-for-agent

- [ ] Exact codec lookup precedes named-type, temporal, generic, and wrapper handling at each typed node.
- [ ] `omitempty` is evaluated before lookup and map keys never consult codecs.
- [ ] Each encountered node invokes its marshaler exactly once during preflight and reuses the cached semantic value during emission.
- [ ] Callback user data and selected allocator are delivered exactly; nonzero callback codes and allocator failures remain distinct.
- [ ] Successful callback values are validated for text, temporal, container, duplicate, cycle, alias, allocator, depth, and size invariants.
- [ ] The package destroys every successful callback value exactly once on success or any later allocation/writer/error path.
- [ ] Allocated and writer output remains canonical and byte-identical, including concurrent calls through a frozen registry.
- [ ] Callback re-entry and source mutation/borrow retention remain prohibited and are documented at the public seam.

# 26 — Typed/codec properties and fuzzing

**What to build:** Prove the completed typed and codec workflows under deterministic generation, ownership faults, and replayable coverage-guided mutation.

**Blocked by:** 18 — Early semantic fuzz targets; 24 — Custom unmarshal codecs.

**Status:** ready-for-agent

- [ ] Generated supported application values round-trip by represented TOML value under the frozen missing/default and ownership rules.
- [ ] Paired codecs satisfy represented-value round trips, exact lookup precedence, callback transactionality, and deterministic callback order.
- [ ] Preflight failures leave destinations unchanged and installation failures leave only recursively cleanable committed units.
- [ ] Representative struct, map, sequence, pointer, optional, `any`, tag, unknown-field, and active-cycle cases are included.
- [ ] A typed/codec coverage-guided target remains panic-free, leak-free, and deterministic under replay.
- [ ] Allocation and writer failures preserve exact errors, no-preflight-write behavior, and temporary cleanup.
- [ ] Every minimized finding becomes a focused public-API regression fixture with its replay seed.

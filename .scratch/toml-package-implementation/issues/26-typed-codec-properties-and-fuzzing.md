# 26 — Typed/codec properties and fuzzing

**What to build:** Prove the completed typed and codec workflows under deterministic generation, ownership faults, and replayable coverage-guided mutation.

**Blocked by:** 18 — Early semantic fuzz targets; 24 — Custom unmarshal codecs.

**Status:** resolved

- [x] Generated supported application values round-trip by represented TOML value under the frozen missing/default and ownership rules.
- [x] Paired codecs satisfy represented-value round trips, exact lookup precedence, callback transactionality, and deterministic callback order.
- [x] Preflight failures leave destinations unchanged and installation failures leave only recursively cleanable committed units.
- [x] Representative struct, map, sequence, pointer, optional, `any`, tag, unknown-field, and active-cycle cases are included.
- [x] A typed/codec coverage-guided target remains panic-free, leak-free, and deterministic under replay.
- [x] Allocation and writer failures preserve exact errors, no-preflight-write behavior, and temporary cleanup.
- [x] Every minimized finding becomes a focused public-API regression fixture with its replay seed.

The new `tests/typed_fuzz` public-seam suite generates bounded application owners and proves allocated, writer, typed-unmarshal, and exact paired-codec workflows under replay seed `123456789`. It preserves missing and ignored ownership, compares represented values rather than allocation identity, records deterministic codec order, distinguishes immutable preflight from recursively cleanable installation prefixes, and retains named replay artifacts for minimized findings. Fixed-shape fail-at-N sweeps cover every allocation ordinal plus post-last success, while the codec writer matrix covers every call ordinal, count class, and exact `io.Error` with canonical-prefix, no-retry, and temporary-cleanup checks. The same package builds as one stdin artifact target spanning round trips, callback transactionality, unknown fields, active cycles, marshal-only `any`, writer faults, and allocation faults; sanitizer-backed campaign execution remains assigned to issue 27.

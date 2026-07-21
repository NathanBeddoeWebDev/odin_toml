# 17 — Semantic properties and official encoder gate

**What to build:** Prove semantic composition and official encoder compatibility through public workflows using deterministic generated values and the pinned corpus adapter.

**Blocked by:** 13 — Stateful tables and arrays of tables; 16 — Semantic writer encoding.

**Status:** resolved

- [x] A test-only encoder adapter accepts the official protocol and emits TOML using only public semantic lifecycle and unparse operations.
- [x] Adapter negative cases reject malformed or unsupported protocol values deterministically.
- [x] The official report records zero encoder failures and zero skips under literal TOML 1.1.0.
- [x] Deterministic generated semantic trees satisfy parse/unparse semantic equivalence and canonical byte idempotence.
- [x] Clone independence, repeated encoding determinism, table/array order, and allocated/writer identity hold for replayable generated cases.
- [x] Every discovered corpus or property defect is minimized into a focused public regression before closure.

The pinned combined corpus gate records 214 decoder passes, 214 encoder passes, 467 invalid-input passes, zero failures, and zero skips. Replayable generated documents are composed through public `set`, then checked through clone, parse, allocated unparse, and writer unparse workflows. Initial adapter runs exposed the pinned core JSON parser's empty-key loss and acceptance of trailing JSON values; focused regressions now retain both cases while the adapter's ordered protocol reader preserves empty keys and requires one complete input value.

# 17 — Semantic properties and official encoder gate

**What to build:** Prove semantic composition and official encoder compatibility through public workflows using deterministic generated values and the pinned corpus adapter.

**Blocked by:** 13 — Stateful tables and arrays of tables; 16 — Semantic writer encoding.

**Status:** ready-for-agent

- [ ] A test-only encoder adapter accepts the official protocol and emits TOML using only public semantic lifecycle and unparse operations.
- [ ] Adapter negative cases reject malformed or unsupported protocol values deterministically.
- [ ] The official report records zero encoder failures and zero skips under literal TOML 1.1.0.
- [ ] Deterministic generated semantic trees satisfy parse/unparse semantic equivalence and canonical byte idempotence.
- [ ] Clone independence, repeated encoding determinism, table/array order, and allocated/writer identity hold for replayable generated cases.
- [ ] Every discovered corpus or property defect is minimized into a focused public regression before closure.

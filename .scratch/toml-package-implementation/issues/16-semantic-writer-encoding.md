# 16 — Semantic writer encoding

**What to build:** Stream canonical semantic output directly to an Odin writer only after complete package-controlled preflight, with exact writer-contract behavior.

**Blocked by:** 02 — Adversarial test kit; 15 — Canonical allocated semantic encoding.

**Status:** ready-for-agent

- [ ] Writer and allocated forms share one spelling plan and produce byte-identical successful output.
- [ ] Empty output performs zero writer calls.
- [ ] Configuration, source validation, depth, size, and allocation failures are detected before the first writer call.
- [ ] Each writer result is consumed exactly once and no short or failed write is retried.
- [ ] Explicit writer errors, invalid byte counts, and nil-error short writes follow the frozen precedence and exact error payloads.
- [ ] On I/O failure, accepted bytes are an exact prefix of canonical allocated output and package scratch is cleaned.
- [ ] Every observed call ordinal and valid or invalid count/error combination is covered by the scripted writer.

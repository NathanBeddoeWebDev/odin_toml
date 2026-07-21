# 06 — Canonical binary64-format gate

**What to build:** Establish deterministic shortest correctly rounded binary64 formatting under the approved TOML canonical profile before semantic or typed encoding depends on it.

**Blocked by:** 01 — Reproducible scaffold and frozen declarations.

**Status:** ready-for-agent

- [ ] Every finite nonzero binary64 value uses the shortest decimal that reparses exactly under the frozen fixed/scientific selection rule.
- [ ] Positive and negative zero, infinities, integer-looking finite values, exponent spelling, and all NaN payloads use their exact canonical spellings.
- [ ] Named raw-bit vectors and deterministic raw-bit samples agree with the pinned test-only Ryu oracle.
- [ ] The formatting result is stable across runs and supported platforms.
- [ ] Oracle source and licensing are recorded, and no oracle code is linked into either runtime package.
- [ ] Failure to satisfy exact formatting is reported as a design blocker rather than hidden behind self-round-trip tests.

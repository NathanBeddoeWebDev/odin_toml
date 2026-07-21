# 05 — Correct decimal-to-binary64 gate

**What to build:** Establish an implementation-feasible, correctly rounded conversion from finite TOML decimal text to binary64, independently proven before public float parsing depends on it.

**Blocked by:** 01 — Reproducible scaffold and frozen declarations.

**Status:** ready-for-agent

- [ ] Finite decimals convert with round-to-nearest, ties-to-even behavior across normal and subnormal ranges.
- [ ] Signed zero, signed underflow, adjacent values, halfway cases, and finite overflow follow the approved rules.
- [ ] An independent exact-rational oracle brackets neighboring binary64 values and selects by exact distance rather than reusing the runtime algorithm.
- [ ] Named edge vectors and deterministic samples agree bit-for-bit with the independent oracle.
- [ ] Oracle code remains test-only and no external TOML implementation is used as proof.
- [ ] Failure to satisfy exact conversion is reported as a design blocker rather than replaced by a weaker or platform-dependent algorithm.

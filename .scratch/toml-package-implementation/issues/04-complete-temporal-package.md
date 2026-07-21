# 04 — Complete temporal package

**What to build:** Deliver the allocation-free public temporal values and operations needed to preserve all four TOML temporal kinds without inventing timezone or calendar information.

**Blocked by:** 01 — Reproducible scaffold and frozen declarations.

**Status:** ready-for-agent

- [ ] Public validation accepts exactly the approved proleptic-Gregorian, time, nanosecond, leap-second, known-offset, and unknown-offset ranges.
- [ ] Validation errors and component/operand precedence match the frozen `temporal.Error` contract.
- [ ] Civil comparisons validate both operands and produce deterministic ordering.
- [ ] Instant comparison handles known displacement, preserves unknown-offset state, and reports non-comparable leap seconds exactly.
- [ ] Every approved conversion to and from core time representations succeeds only without information loss or machine-timezone inference.
- [ ] Boundary tests cover years 0000 and 9999, Gregorian month/day neighbors, second 60, nanoseconds, offsets ±1439, and unknown `-00:00`.
- [ ] Results remain unchanged under different machine timezone settings and the package performs no allocation.

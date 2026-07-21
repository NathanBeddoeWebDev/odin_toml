# 11 — Strict scalar-document parsing

**What to build:** Parse complete TOML 1.1 scalar-assignment documents into owned semantic trees with strict text handling and actionable allocation-free diagnostics.

**Blocked by:** 04 — Complete temporal package; 05 — Correct decimal-to-binary64 gate; 08 — Semantic owner lifecycle.

**Status:** ready-for-agent

- [ ] Whole-input RFC 3629 UTF-8 preflight rejects BOMs, bare CR, invalid controls, non-TOML whitespace, malformed UTF-8, and trailing or partially consumed input.
- [ ] Bare and quoted keys plus basic, literal, and multiline strings follow exact escape, newline, and control rules.
- [ ] Booleans, checked `i64` integers, finite floats, infinities, NaNs, and all four temporal kinds produce their exact semantic values.
- [ ] Float results match independent expected bits, temporal fractions truncate after nanoseconds, and unknown offsets remain distinct from UTC.
- [ ] Scalar-candidate classification and duplicate decoded-key handling follow frozen precedence.
- [ ] Source ranges use zero-based bytes and one-based Unicode-scalar line/columns and remain valid after input release.
- [ ] Every rejection family has a nearest valid neighbor through both parse overloads.
- [ ] Allocation failure is transactional: the result is zero, input is never borrowed, and all partial ownership is cleaned.

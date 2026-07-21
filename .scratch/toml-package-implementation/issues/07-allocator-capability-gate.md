# 07 — Allocator capability gate

**What to build:** Prove and freeze the allocator behavior needed for uniform semantic ownership, transactional failures, exact errors, and external-lifetime destruction.

**Blocked by:** 02 — Adversarial test kit.

**Status:** ready-for-agent

- [ ] Individually freeing allocators support the required arbitrary-order release behavior and exact external errors are preserved.
- [ ] Feature-reporting external-lifetime allocators perform logical destruction and never receive unsupported individual frees.
- [ ] Unreported capability with `.Mode_Not_Implemented` follows the approved transition to logical destruction without invoking global `Free_All`.
- [ ] Unsupported allocation and resize operations remain distinguishable from generic package errors.
- [ ] No tested path falls back to the ambient allocator.
- [ ] Any allocator behavior that cannot support the frozen ownership contract blocks semantic-owner work and is escalated for design review.

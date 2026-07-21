# 22 — Typed unmarshal immutable preflight

**What to build:** Strictly parse and completely validate scalar/struct typed binding before changing the destination, while preserving defaults and ignored ownership.

**Blocked by:** 03 — Reference-Odin RTTI feasibility gate; 14 — Official TOML decoder gate; 19 — Typed marshal: roots, scalars, and struct projection.

**Status:** ready-for-agent

- [ ] Both unmarshal forms strictly parse into temporary ranged semantic state before binding and wrap parse errors exactly.
- [ ] Eligible struct roots and same-category scalar/temporal bindings enforce exact kind and checked range rules.
- [ ] Complete tags, flattening, effective names, root/destination kinds, depth, size, and clean owning-slot state are validated before mutation.
- [ ] Missing fields and ignored subtrees remain uninspected and unchanged.
- [ ] Unknown struct fields are ignored by default and recursively rejected in semantic insertion order when requested.
- [ ] Every configuration, parse, schema, type, range, unknown-field, clean-slot, and preflight-allocation failure leaves the destination byte-for-byte unchanged.
- [ ] Installed source strings are cloned rather than borrowed, and diagnostics remain valid after input release.
- [ ] Successful scalar/struct-leaf binding mutates only matched destinations after complete preflight and installs no owning destination storage.

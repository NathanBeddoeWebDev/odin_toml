# 22 — Typed unmarshal immutable preflight

**What to build:** Strictly parse and completely validate scalar/struct typed binding before changing the destination, while preserving defaults and ignored ownership.

**Blocked by:** 03 — Reference-Odin RTTI feasibility gate; 14 — Official TOML decoder gate; 19 — Typed marshal: roots, scalars, and struct projection.

**Status:** resolved

- [x] Both unmarshal forms strictly parse into temporary ranged semantic state before binding and wrap parse errors exactly.
- [x] Eligible struct roots and same-category allocation-free scalar/temporal bindings enforce exact kind and checked range rules.
- [x] Complete tags, flattening, effective names, root/destination kinds, depth, size, and matched clean owning-slot state are validated before mutation.
- [x] Missing fields and ignored subtrees remain uninspected and unchanged.
- [x] Unknown struct fields are ignored by default and recursively rejected in semantic insertion order when requested.
- [x] Every configuration, parse, schema, type, range, unknown-field, clean-slot, and preflight-allocation failure leaves the destination byte-for-byte unchanged.
- [x] Temporary parsed keys and strings are cloned rather than borrowed, and diagnostics remain valid after input release.
- [x] Successful allocation-free scalar/temporal struct-leaf binding mutates only matched destinations after complete preflight; matched string/container/wrapper installation remains assigned to issue 23.

Typed unmarshal now retains private per-node key/value source ranges through strict parsing, validates complete reflected struct schemas and matched values before mutation, and performs a no-fail assignment pass only for allocation-free leaves. The earlier wording simultaneously required installed strings to be cloned and prohibited owning destination installation; this resolution follows the dependency boundary in issue 23 by making parser-owned source text input-independent here while deferring matched destination string ownership to issue 23.

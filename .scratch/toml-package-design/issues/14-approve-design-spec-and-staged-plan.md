# Approve the package design specification and staged plan

Type: prototype
Status: resolved
Blocked by: 05, 06, 07, 08, 09, 10, 11, 12, 13

## Question

Does a concrete design specification synthesizing every resolved contract—public API sketches, semantic model, ownership table, parser and encoder behavior, typed mappings, diagnostics, conformance criteria, non-goals, risks, and staged implementation plan—fully describe the intended package and provide an implementation-ready handoff the user approves?

## Answer

Yes. The user approved resolution of the final design ticket, and the resulting [Odin TOML 1.1 package design specification](../design-spec.md) plus exhaustive [public interface freeze](../public-interface-freeze.md) are the implementation handoff. They preserve issues 01–13 as normative detail while fixing repository/source responsibilities, module dependency direction, public declarations, implementation stages, stage exit criteria, risk burn-down, external-tool acquisition, benchmark placement, and the remaining cross-ticket integration rules.

The final synthesis explicitly resolves these handoff hazards:

- direct `set` enforces hard depth only relative to its target table because its frozen interface has no document-root context; root-relative operation limits remain clone/parse/encode checks;
- no public builder is added: parsing empty input creates an initialized document, while transparent standalone containers use documented fallible Odin initialization with the correct allocator;
- destroy/remove require zero or valid exclusive allocator-consistent owners and do not attempt unsafe salvage of malformed cyclic/aliased trees;
- a wholly zero projected typed destination is the generally safe mechanical-cleanup pattern; callers retaining ownership in missing/ignored fields must retain application-specific provenance;
- custom unmarshal failure is transactional for its supplied slot, superseding issue 08's earlier provisional allowance;
- leap-second acceptance is structural and preserves second `60` without claiming historical IERS validation;
- scalar error classification and parser stable-node descriptor strategy are deterministic;
- every public error alternative/payload, temporal conversion name, codec declaration, nil-success rule, and attribute is frozen before the compile-gated scaffold step;
- both binary64 conversion directions receive an early feasibility gate;
- `toml-test` is built from the full pinned source commit, benchmarks begin only after correctness, and no extra compile-only target is initially claimed.

No separate throwaway prototype is required before implementation. The staged plan treats the Reference Odin RTTI/ownership probes, allocator lifecycle, and both float directions as early feasibility gates; failure at one returns to design rather than silently weakening a contract.

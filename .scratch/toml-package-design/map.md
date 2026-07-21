# Design a standalone Odin TOML 1.1 package

Label: wayfinder:map

## Destination

An approved design specification and staged implementation plan for a standalone repository-root Odin `toml` package, plus its reusable sibling `temporal` package, that strictly decodes and deterministically encodes TOML 1.1 using the installed Odin encoding packages as its API and memory-management precedent.

## Notes

- TOML 1.1 source of truth: <https://toml.io/en/v1.1.0>
- Reference Odin: locally installed `dev-2026-07:2c25fb924`, commit `2c25fb92420bfa31da62e2194b0cc2cb8bd54cf8`.
- Reference packages: `/Users/nathan/Developer/Odin/core/encoding/json` and `/Users/nathan/Developer/Odin/core/encoding/ini`.
- Every session should consult the `odin`, `odin-memory`, `odin-packages`, and `domain-modeling` skills; use `grilling` for HITL decisions.
- Mirror current `encoding/json` public and allocator conventions where applicable, but explicitly raise cleaner TOML-specific concepts.
- Include both an allocator-owned semantic document tree and reflection-based typed marshal/unmarshal APIs.
- Preserve semantic table insertion order, not comments, whitespace, quote style, or other concrete syntax.
- Strict TOML 1.1 only. Deterministic output uses insertion order for documents, declaration order for structs, and lexically sorted map keys.
- Model all four TOML temporal kinds distinctly through a reusable sibling `temporal` package. Provide custom per-type codecs, optional unknown-field rejection, explicit unsupported-nil errors, rich source/path diagnostics, and a nesting-depth limit.
- APIs consume complete `string`/`[]byte` documents and encode to allocated text or `io.Writer`; filesystem and streaming-reader helpers are excluded.
- A typed decode failure may leave the destination partially populated, but package-owned temporary allocations must be cleaned up and transferred ownership documented.
- Validate with the official TOML test corpus plus Odin-specific reflection, writer, and allocator tests.
- Research findings remain in this local tracker because the repository has not yet been initialized as a Git repository; move them to research branches once version control exists if desired.

## Decisions so far

<!-- Closed-ticket context pointers are appended here. The decision detail remains in its ticket. -->

- [Establish the installed Odin encoding API and memory precedent](issues/01-establish-installed-odin-encoding-precedent.md) — Follow JSON's layered, allocator-explicit, writer-first shape while avoiding its global state and ownership/error-path quirks.
- [Extract the TOML 1.1 semantic and conformance requirements](issues/02-extract-toml-1-1-requirements.md) — Conformance requires ABNF plus stateful prose semantics, with canonical ordering and edge-case policies supplied by this package.
- [Establish Odin temporal and reflection capabilities](issues/03-establish-odin-temporal-reflection-capabilities.md) — Odin supports component validation and RTTI traversal but requires dedicated temporal types and explicit ownership-safe reflected assignment.
- [Define official TOML conformance-test integration](issues/04-define-official-conformance-test-integration.md) — Pin `toml-test` v2.2.0 at its immutable commit, explicitly select TOML 1.1, and supplement its semantic checks with Odin-specific tests.
- [Choose the public package surface](issues/05-choose-public-package-surface.md) — Expose only semantic-document, typed-binding, and writer workflows through a small JSON-familiar, allocator-explicit, per-call-configured API.
- [Define the four-kind temporal contract](issues/06-define-temporal-contract.md) — Put reusable civil/fixed-offset values, validation, comparison, and explicit core-time conversion in `temporal`, while TOML owns exact typed binding and canonical syntax without inferred date or timezone state.
- [Choose the semantic document model and mutation invariants](issues/07-choose-semantic-document-model.md) — Use a transparent no-null value tree with one insertion-ordered entry sequence per table, generic heterogeneous arrays, structural arrays-of-tables, decoded key/index paths, and only direct invariant-preserving table mutation.
- [Define allocation, ownership, and failure-cleanup contracts](issues/08-define-allocation-ownership-contracts.md) — Use uniform allocator-owning documents, explicit deep clone/destruction, clone-in table mutation, borrowed lookup pointers, transactional owner-producing operations, partial in-place typed decode, and allocation-free diagnostics.
- [Define the strict decoder and diagnostic contract](issues/09-define-strict-decoder-contract.md) — Use a private pull lexer and transactional stateful parser with strict UTF-8 and complete-input validation, bounded depth, transient TOML definition provenance, precise allocation-free source/path diagnostics, and exact allocator cleanup.
- [Define deterministic TOML encoding](issues/10-define-deterministic-encoder-contract.md) — Use one all-inline canonical TOML profile with quoted basic-string keys, exact scalar spellings, semantic insertion/struct declaration/sorted-map ordering, preflight validation, bounded depth, and exact writer/allocation failure behavior.
- [Define typed marshal, unmarshal, and struct-tag semantics](issues/11-define-typed-binding-and-tags.md) — Use closed same-category binding, table-shaped roots, exact field/tag projection, checked scalar conversions, zero-state ownership preflight, optional unknown-field rejection, and caller-cleanable partial installation.
- [Choose the custom-codec registry model](issues/12-choose-custom-codec-registry-model.md) — Use a caller-owned per-call exact-`typeid` registry with independent directional codecs, semantic-value marshal results, transactional custom destination slots, and no global or raw-text escape hatch.
- [Define validation and acceptance criteria](issues/13-define-validation-and-acceptance.md) — Require pinned TOML 1.1 conformance plus focused API/golden/property tests, exhaustive Odin allocator and writer faults, fuzzing, sanitizer/race checks, and a documented platform/mode matrix.
- [Approve the package design specification and staged plan](issues/14-approve-design-spec-and-staged-plan.md) — Approve the consolidated [design specification](design-spec.md), exhaustive [public interface freeze](public-interface-freeze.md), exact source responsibilities, integration rules, risk gates, and correctness-first implementation stages through release evidence and non-gating benchmark baselines.

## Deferred implementation evidence

- No design question remains open. Stage 0 only verifies and transcribes the frozen public declaration blueprint into Reference-Odin syntax; it may not make new interface or semantic choices.
- Initial acceptance intentionally has no performance threshold; Stage 10 records reproducible baselines after all correctness gates are green.

## Out of scope

- Lossless/CST editing and preservation of comments, whitespace, quoting, or source layout.
- Filesystem convenience APIs and streaming `io.Reader` decoding.
- Schema validation, configuration merging, and nonstandard or legacy TOML extensions.
- Implementing the package during this wayfinding effort.

# Choose the public package surface

Type: grilling
Status: resolved
Blocked by: 01, 02

## Question

Which public procedure families, option types, error types, naming conventions, input/output overloads, custom-codec hooks, and compatibility promises should the repository-root `toml` package expose so that it feels consistent with installed `encoding/json` while remaining idiomatic for TOML?

## Answer

Expose three workflows only: semantic document parsing/serialization, reflection-based typed marshal/unmarshal, and direct writer output. The initial procedure families are `parse` as a group of `parse_bytes` and `parse_string`; `unparse` and `unparse_to_writer` for semantic documents; `marshal` and `marshal_to_writer` for typed encoding; and `unmarshal` plus `unmarshal_string` for typed decoding. Add canonical semantic-document destruction and allocator-selecting deep clone operations once the document model determines their exact names.

Mirror installed JSON where familiarity matters: `marshal` returns caller-owned `[]byte`, `unparse` returns caller-owned `string`, writer procedures return only their operation-specific errors, `marshal` accepts `any`, and typed unmarshal accepts `^$T`. Do not expose redundant `encode`/`decode` aliases, `unmarshal_any`, reflected setters, builders, tokenizers, parser state, borrowed iterators, filesystem helpers, streaming readers, or standalone validation.

Expose `Parse_Options`, `Unmarshal_Options`, and `Marshal_Options`. Top-level allocating and decoding calls take options by value with `{}` defaults; writer calls take a stable options pointer. Options contain caller policy only, never parser or encoder working state. Reserve per-call custom-codec configuration in marshal/unmarshal options and provide no package-global registration API; the concrete registry and callback contracts remain for the dedicated codec decision.

Expose separate value-based `Parse_Error`, `Unparse_Error`, `Unmarshal_Error`, and `Marshal_Error` families, sharing structured source-position/path diagnostic components where appropriate. Their exact variants and ownership remain downstream decisions. Every potentially allocating public entry point—including writer calls that may need deterministic key-sorting storage—takes `allocator := context.allocator` and `loc := #caller_location`.

Mark all non-API declarations `@(private)`. Issue 08 refines the allocator rule for owner-bound mutation: `set` and `remove` use the allocator retained by their initialized table rather than accepting a caller-supplied allocator that could mismatch the owner. Before 1.0, documented breaking changes are allowed; from 1.0, semantic versioning protects documented declarations, ownership contracts, strict TOML semantics, and deterministic output bytes. The package accepts strict TOML 1.1 only unless a future explicit API decision adds another version. Initially support and test the exact Reference Odin revision (`dev-2026-07:2c25fb924`); make no untested promise for older compilers and document future supported revisions through CI.

# Extract the TOML 1.1 semantic and conformance requirements

Type: research
Status: resolved
Blocked by: none

## Question

What complete set of lexical, structural, value-model, table-definition, array-of-tables, temporal, duplicate-definition, and encoding-validity rules from the official TOML 1.1 specification constrain the semantic tree, strict decoder, and deterministic encoder design?

## Answer

Strict conformance requires the canonical ABNF plus prose-level semantic validation: valid Unicode scalar text, checked integer representation, calendar and temporal validation, complete input consumption, and stateful duplicate/table-definition enforcement. The final semantic model is a root string-keyed table over strings, signed integers, floats, booleans, four distinct temporal kinds, ordered heterogeneous arrays, and nested tables; source spelling and table-definition provenance are parse-time rather than semantic state. Parsing nevertheless needs transient states for implicit, header-defined, dotted-defined, sealed inline, and array-of-tables paths, including latest-element binding. TOML does not define canonical ordering or spelling, so deterministic output is a package contract. Leap seconds, `-00:00`, excess fractional precision, float overflow, NaN normalization, and the exact deterministic traversal remain explicit design decisions.

Research asset: [TOML 1.1 semantic and conformance requirements](../research/toml-1.1-requirements.md)

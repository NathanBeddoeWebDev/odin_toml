# Context

## Glossary

- **Standalone TOML library**: An independently distributed Odin library that provides TOML encoding and decoding; it is not part of the Odin core distribution.
- **Reference Odin**: The locally installed Odin distribution used to study established `encoding/json` and `encoding/ini` conventions (`dev-2026-07:2c25fb924`).
- **Semantic document tree**: The allocator-owned TOML data model containing values, ordered tables, arrays, and four distinct temporal kinds, without comments, whitespace, quote style, or other source-layout details.
- **Semantic table**: An insertion-ordered collection of unique decoded string keys and semantic values; insertion order is package policy even though TOML assigns ordinary table entries no order significance.
- **Semantic path**: An ordered sequence of exact decoded table keys and array indexes rooted at a semantic value; dots within a key are data, not separators.
- **Allocation owner**: The allocator that physically owns an allocation and governs how its storage is eventually reclaimed or retained, whether by arbitrary-order individual release or an external lifetime such as an arena reset.
- **Owning value**: The single program value responsible for ending access to its reachable allocations and releasing them through their allocation owner; an ordinary shallow copy is only a borrowed alias, not another owner.
- **Borrowed view**: A non-owning pointer or slice valid only while its documented source remains alive and unchanged by an invalidating mutation.
- **Ownership transfer**: A successful operation boundary after which responsibility for releasing a value moves from one owner to another; failed operations do not transfer ownership unless their partial-result contract explicitly says otherwise.
- **Uniform-allocation document**: A semantic document tree whose reachable owned allocations all belong to the allocator selected when the document was created or cloned.
- **Array of tables**: A semantic array whose elements are tables; its source spelling and latest-element parser state are not retained after decoding.
- **Typed binding**: Reflection-based conversion between TOML values and application-defined Odin values through marshal/unmarshal procedures and `toml` struct tags.
- **Effective field name**: The exact decoded TOML key assigned to a selected Odin struct field after applying renaming and anonymous-`using` flattening; effective names are case-sensitive and unique within one projected table.
- **Clean destination slot**: A typed-unmarshal destination location that owns no storage the package could overwrite; owning kinds are exactly zero while allocation-free scalar defaults may remain populated.
- **Optional union**: An Odin union with exactly one non-nil alternative and an available nil state; a present TOML value selects that alternative, while TOML never synthesizes nil.
- **Unknown field**: A decoded table key for which a projected destination struct has no effective field name; maps do not have unknown fields.
- **Strict TOML**: Acceptance of exactly TOML 1.1 syntax and semantics, with duplicate definitions and nonstandard extensions rejected.
- **Table definition state**: Transient source-interpretation history distinguishing implicit, header-defined, dotted-defined, inline-sealed, and array-of-tables paths; it determines whether later definitions are legal but is not part of the semantic document tree.
- **Temporal package**: The reusable vendored git package that owns validated civil and fixed-offset temporal values and operations without parsing or formatting TOML text.
- **Local temporal value**: A date, time, or date-time whose value intentionally contains no UTC offset or timezone; “local” never means the machine’s current timezone.
- **Unknown offset**: The offset state represented by RFC 3339 `-00:00`, distinct from a known zero UTC offset and preserved without timezone inference.
- **Codec registry**: A caller-owned, per-call mapping from an exact Odin `typeid` to directional typed-binding callbacks; it is borrowed during a TOML operation and owns only its lookup storage, never callback state.
- **Custom codec**: A registered conversion boundary between one exact application type and a semantic TOML value; it cannot read parser tokens or write raw TOML text.

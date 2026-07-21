# Choose the semantic document model and mutation invariants

Type: grilling
Status: resolved
Blocked by: 01, 02, 05, 06

## Question

What `Document`, `Value`, `Table`, array, path, scalar, and temporal representations should be public; how should ordered lookup and arrays-of-tables be modeled; and which `get`, `set`, and `remove` operations are needed to preserve TOML semantic invariants without exposing diverging internal state?

## Answer

Use a transparent, allocator-owned tree following Reference Odin JSON's value style, but represent every table by one ordered entry sequence rather than by a map or by public entries plus an index. This is the semantic model:

```odin
Integer :: i64
Float   :: f64
Boolean :: bool
String  :: string

Array :: distinct [dynamic]Value
Table :: distinct [dynamic]Entry

Entry :: struct {
    key:   String,
    value: Value,
}

Value :: union #no_nil {
    String,
    Integer,
    Float,
    Boolean,
    temporal.Offset_Date_Time,
    temporal.Local_Date_Time,
    temporal.Local_Date,
    temporal.Local_Time,
    Array,
    Table,
}

Document :: struct {
    root: Table,
}
```

`Document.root` is always a table. `Value` has no null, missing, generic temporal, array-of-tables, inline-table, or arbitrary application-value variant. Putting `String` first makes a zero-valued `#no_nil` `Value` the valid empty string. `Integer` is exactly signed 64-bit; `Float` is exactly IEEE-754 binary64 and retains negative zero, infinities, and host NaN values, while deterministic NaN spelling remains an encoder decision. Strings and keys are decoded, valid UTF-8 Unicode scalar text compared exactly, without normalization or case folding. The four temporal alternatives are the exact validated types chosen in issue 06.

`Document {root: Table}` fixes the public semantic payload. Issue 08 may add allocator bookkeeping to the physical `Document` representation when it freezes destruction and ownership; allocator metadata is not part of TOML semantics.

### Tables and order

`Table`'s entry sequence is the sole authoritative state for membership, values, and insertion order. Keys are unique within a valid table. Do not store a persistent lookup map, public or private, and do not expose a second key sequence. Public lookup is linear; the strict parser may use transient private maps while constructing a document, provided it discards them before returning the semantic tree. This favors one non-diverging representation and predictable destruction over speculative constant-time lookup. A later performance change requires evidence and must preserve the same interface and ordering contract.

Insertion order is assigned when an entry first comes into semantic existence:

- parsing a key, implicit parent table, standard table, or array-of-tables path inserts each previously absent entry at that point;
- later legal definition or population of an existing table does not move its entry;
- the first `[[path]]` inserts the array entry, and later elements append to that array without moving it;
- replacing an existing value through `set` preserves its position;
- inserting an absent key through `set` appends it;
- `remove` uses stable compaction, and removing then reinserting a key puts it at the end;
- deep clone preserves table insertion order and array element order exactly.

TOML itself does not assign significance to ordinary table order; preserving it is this package's deterministic semantic-document policy.

### Arrays and arrays of tables

`Array` is ordered and heterogeneous. Native array order is semantic, and no homogeneity restriction is imposed.

An array of tables is not a distinct value kind or flagged array. It is simply an `Array` whose elements happen to be `Table` values. Consequently an array parsed from `[[x]]` and an equivalent array of inline tables have the same semantic representation, while an empty array has no latent element kind. Current/latest array-of-tables binding, inline-table sealing, and implicit/header/dotted definition provenance are strict-parser state and are discarded after successful parsing. Issue 10 chooses canonical syntax from the resulting shape without consulting provenance.

### Paths

Expose paths for diagnostics and other interfaces as decoded semantic segments:

```odin
Path_Index :: distinct int

Path_Segment :: union #no_nil {
    String,
    Path_Index,
}

Path :: distinct []Path_Segment
```

A string segment selects one exact table key and an index segment selects one array element. The empty path denotes the diagnostic or traversal root. Negative indexes are invalid. A dot in a string segment is data: `{"a.b"}` is one segment, while `{"a", "b"}` is two. Paths never parse TOML dotted-key syntax and never retain source quoting. Issue 08 decides whether error paths own or borrow their segment strings.

Do not initially expose path-based `set` or `remove`, or automatic creation of missing parents. Those operations introduce ambiguous array growth, implicit allocation, pruning policy, and a larger transactional interface without adding semantic capability. Callers navigate explicit `Table` and `Array` values instead. A read-only path traversal helper may be added later only if repeated caller demand justifies it; it must start from a `Value`, so an empty path can return that starting value without inventing a root-value variant.

### Mutation interface and invariants

Expose only direct table `get`, `set`, and `remove` operations initially. Arrays are transparent dynamic arrays with no TOML-specific membership invariant beyond element order and valid child values, so callers use ordinary dynamic-array indexing and mutation while preserving order; TOML-specific array wrappers would be shallow. Issue 08 may still require ownership-aware array helpers if ordinary mutation cannot express safe transfer and cleanup. Do not add `contains`, key/value view, iterator, builder, clear, array-of-tables, or dotted-path mutation procedures.

The table operations have these semantic contracts; issue 08 freezes their ownership-bearing signatures, allocator parameters, returned-value transfer, and borrow invalidation rules:

- `get(table, key)` compares an exact decoded key and reports the matching value or absence without allocation or mutation.
- `set(table, key, value)` validates its immediate input, replaces an existing entry in place, or appends one absent entry. It never interprets dots, creates parents, or creates a duplicate. Any failure leaves the table semantically unchanged.
- `remove(table, key)` removes at most the exact direct entry, preserves survivor order, reports absence, and does not prune empty ancestor tables. Whether it destroys or transfers the removed key/value is issue 08's decision.

Semantic mutation is not source replay. Replacing a scalar with a table, a table with an array, or one temporal kind with another is valid tree mutation. Duplicate-definition, table-redefinition, dotted-key, sealed-inline-table, and latest-array-element rules apply only while interpreting TOML source and stay behind the parser seam.

Because Odin has no private struct fields and these containers intentionally follow JSON's transparent style, callers can bypass the procedures with direct `append`, key mutation, shallow copies, or element assignment. There is still only one canonical table state, but uniqueness and ownership are guaranteed only for package-produced trees and operations following the documented interface. Parsing, cloning, and sanctioned mutation produce valid, acyclic, exclusively owned trees. Unparse must reject malformed caller-constructed trees—at least duplicate keys, invalid text, invalid temporals, invalid path-independent value state, excessive nesting, cycles, and ownership-invalid aliasing as far as issue 08 makes detectable—rather than emitting invalid TOML or recursing indefinitely.

Opaque raw-pointer containers were rejected because they require constructors/builders excluded by issue 05, make every scalar-tree use indirect, and create harder aliasing and use-after-free contracts in a language without automatic lifetime management. Ordered entries plus a persistent hash index were rejected because Odin cannot hide struct fields and the two stores could diverge; a cache that can be stale adds implementation and failure modes before benchmarks show a need.

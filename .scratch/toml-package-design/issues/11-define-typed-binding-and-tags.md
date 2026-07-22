# Define typed marshal, unmarshal, and struct-tag semantics

Type: grilling
Status: resolved
Blocked by: 01, 03, 05, 06, 07, 08

## Question

How should TOML values map to Odin scalars, structs, arrays, slices, maps, pointers, unions, `any`, and custom types; what exact `toml` tag grammar and omit rules apply; how are unknown fields handled; which conversions are rejected; and what destination state and ownership remain after typed-decoding failure?

## Answer

Use a closed, reflection-based binding model: TOML semantic kinds bind only to explicitly compatible Odin kinds, narrowing is checked, and there are no text, numeric, enum, timezone, or union-inference coercions. Typed roots always represent TOML's root table. Marshal performs complete preflight before output; unmarshal strictly parses, preflights the complete generic binding, and only then begins in-place installation. Exact-`typeid` custom-codec lookup precedes these generic rules, while issue 12 owns the registry and callback contract.

### Typed roots and options

After exact-`typeid` codec lookup, generic typed marshal must resolve its source through non-nil `any`, pointer, and supported optional-union wrappers to either a struct or an eligible map. Generic typed unmarshal must likewise resolve its destination type to a struct or eligible map; its outer `^$T` argument is the API's writable destination and is not itself a TOML path segment. Scalars, temporals, arrays, slices, and dynamic arrays are invalid generic roots. The package never invents a key around a non-table root.

Keep `Document`, `Table`, and `Value` in the semantic-document workflow rather than special-casing them in generic typed binding. An exact root custom marshaler may accept another registered source type, but the semantic value it returns must be a `Table`. An exact root custom unmarshaler receives the parsed root table and may populate another registered destination type. Thus custom codec lookup precedes generic root-shape rejection in both directions; issue 12 owns callback mechanics and failure behavior.

Finalize the generic unmarshal policy fields as:

```odin
Unmarshal_Options :: struct {
    max_depth:             int, // 0 selects 128
    reject_unknown_fields: bool,
    // Per-call codec configuration is added by issue 12.
}
```

`max_depth` has the same default, `1..256` explicit range, hard limit, and semantic-path definition as parse and marshal. Reflection wrappers, named-type unwrapping, pointers, and optional unions do not add depth; every TOML table key or array index does.

### Scalar compatibility and conversion

Codec lookup occurs on the exact destination or source `typeid` before generic named-type handling. Without a codec, bind only within one semantic category:

| TOML kind | Generic Odin kind | Rules |
| --- | --- | --- |
| string | `string` or named/distinct string | Validate scalar UTF-8; unmarshal clones with the selected allocator. `cstring` is not supported. |
| boolean | `bool` or named/distinct boolean | No integer or textual boolean conversion. |
| integer | signed or unsigned integer kinds and named/distinct forms | Unmarshal requires the `i64` TOML value to fit the destination exactly. Marshal requires the source value to fit TOML `i64`; negative-to-unsigned and unsigned/wide overflow are errors. |
| float | `f16`, `f32`, `f64`, and named/distinct forms of those widths | Marshal widens supported narrower values to `f64`. Unmarshal uses IEEE round-to-nearest for narrower destinations; ordinary precision loss and signed underflow are allowed, while finite overflow to infinity is rejected. TOML infinities and NaNs bind to supported floating types. Wider or otherwise unsupported float formats are rejected. |
| offset date-time | exactly `temporal.Offset_Date_Time` | Validate before marshal; no implicit conversion. |
| local date-time | exactly `temporal.Local_Date_Time` | Validate before marshal; no implicit conversion. |
| local date | exactly `temporal.Local_Date` | Validate before marshal; no implicit conversion. |
| local time | exactly `temporal.Local_Time` | Validate before marshal; no implicit conversion. |

Reject integer-to-float, float-to-integer, boolean-to-integer, string-to-temporal, temporal-to-string, and every other cross-category coercion. Enums and bit sets do not bind from strings or integers. The exact temporal types are terminal special cases: a named/distinct application wrapper around one does not inherit its temporal meaning and needs a custom codec.

Parsing has already normalized TOML NaNs and excess temporal fraction digits under issues 06 and 09. Typed binding does not recover discarded syntax or preserve host-only NaN payload metadata.

### Struct projection

A TOML table binds to a struct through a deterministic field projection:

- Untagged ordinary fields use their exact Odin field name as one decoded TOML key.
- Matching is case-sensitive and performs no Unicode normalization, case folding, dotted-key interpretation, or fallback matching.
- A named `using` field remains one ordinary named field.
- An anonymous `using _: Struct` field is recursively flattened. Its selected children expand at the wrapper's declaration position, preserving declaration order for marshal.
- Only an absent/empty `toml` tag or `toml:"-"` is valid on the anonymous flattened wrapper. The latter ignores its complete subtree. Renaming or `omitempty` on the wrapper is invalid; child tags apply normally.
- `toml:"-"` fields are excluded in both directions and their type and value are not otherwise inspected.
- Every other selected field participates in struct-plan validation. On unmarshal, unsupported selected destination fields are errors even when the corresponding TOML key is absent; callers must explicitly ignore them.

After recursive flattening and renaming, every selected field must have a unique effective TOML key. Any collision is a struct-definition error; explicit tags, shallower depth, declaration order, and source order do not choose a winner. Validate tags and collisions in declaration order before traversing values at that struct depth.

A missing TOML key leaves its destination field unchanged. There is no required-field mode. Allocation-free scalar defaults are consequently permitted. Existing ownership in missing or ignored fields remains entirely application-owned.

### Struct-tag grammar and omission

The complete initial tag language is:

```text
toml:"[name][,omitempty]"
toml:"-"
```

An absent tag, `toml:""`, or an empty name as in `toml:",omitempty"` selects the Odin field name. The name is a literal decoded key, so a dot is data rather than a path separator. A comma cannot be represented in a struct-tag name; maps remain able to represent such keys. `toml:"-"` is the complete ignore form and cannot have options.

Scan and validate the selected field's complete raw Odin struct-tag list rather than relying solely on `reflect.struct_tag_lookup`. Reject malformed surrounding tag syntax and more than one `toml` entry on the same field; neither an earlier malformed entry nor first-duplicate lookup may silently hide TOML metadata. Then split the single `toml` value on literal ASCII commas without trimming. The only option is exact lowercase `omitempty`. Reject unknown, duplicate, empty, trailing, or whitespace-padded options. Reject a renamed effective key that is not valid Unicode scalar text. Do not initially add `inline`, `required`, stringification, case-folding, or conversion options.

`omitempty` affects marshal only. It omits these values before value-level traversal:

- `false`;
- numeric zero, including either floating signed zero;
- a zero-length string;
- a zero-length fixed/enumerated array, slice, dynamic array, or map;
- a nil ordinary pointer;
- a nil supported optional union;
- a genuinely nil `any`.

A non-nil pointer or `any` is not empty merely because its contained value is empty. Nonzero-length fixed arrays and all structs, including temporal structs, are never empty. An invalid zero temporal therefore remains an error unless absence is represented by an omitted nil wrapper. Tags and field-name collisions are validated even on omitted fields, but omission suppresses value-level failures such as unsupported nil beneath the omitted field.

### Maps

A TOML table binds generically only to a map whose key is `string` or a named/distinct string type. Do not parse integers, enums, temporals, or other text forms from keys. Issue 12 decides whether an exact map-key codec is useful and safe; generic binding does not infer one.

Marshal validates every converted key as Unicode scalar text, checks converted keys for equality, and sorts them by issue 10's unsigned UTF-8 lexical order before traversing values. A collision after conversion is an error; map iteration order never chooses a winner. A nil map is unsupported unless omitted, while an initialized empty map represents an empty table. An eligible empty root map therefore produces the empty document.

Unmarshal requires a matched destination map slot to be nil/zero, initializes it with the call allocator, and binds values recursively in semantic table insertion order. Destination key strings are independently owned. Each generic key/value pair is a commit unit: stage it under package cleanup responsibility and transfer it only when complete. Issue 12's immediate opaque-ownership rule creates one narrow exception: the first successful custom unmarshaler nested in a staged value commits the containing entry to the application. A later failure may leave that entry recursively cleanable and partially installed, while the failing callback's complete slot remains exact zero. If no nested custom unmarshaler has succeeded, the package cleans and removes the staged pair as before. Typed unmarshal never clears or merges into an existing map. [Design review 002](../../../design-reviews/002-custom-unmarshal-map-commit-boundary.md) records the conflict and approved resolution.

### Arrays, slices, and dynamic arrays

A TOML array binds element-by-element to fixed arrays, enumerated arrays, slices, and dynamic arrays. TOML arrays remain heterogeneous; compatibility is checked independently for each destination element.

- Fixed and enumerated arrays require exactly the TOML element count. Never truncate, pad, or retain unmatched elements.
- Marshal preserves linear element order.
- Nil-backed and non-nil-backed zero-length Odin slices both represent an empty TOML array. This is the one nil-capable-container exception: Reference Odin's `make([]T, 0)` is indistinguishable from a nil slice, and slices carry no capacity or allocator metadata with which the package could manufacture and later safely release a distinct empty owner.
- A nil/uninitialized dynamic array is unsupported unless omitted. An initialized empty dynamic array represents `[]`.
- Unmarshal requires matched slice and dynamic-array slots to be zero. A non-empty slice allocation uses the selected allocator; decoding an empty array installs the zero slice without allocating. A dynamic array is initialized with and retains the selected allocator even when empty.
- A non-empty slice of a zero-sized element type has a nonzero logical length but no backing allocation. Its elements are still traversed in order, although a genuinely zero-sized element cannot itself own storage.
- Install slice or dynamic-array storage before populating elements. Elements commit in index order; after failure, completed elements remain destination-owned and untouched elements are zero.
- Fixed-array owning elements that can be reached by the source must initially be zero, while scalar defaults may be overwritten.
- Validate the declared element type even when the source or application container is empty. An unsupported element type does not become supported in a zero-length fixed array, slice, or dynamic array.

Matrix, SIMD, SoA, and fixed-capacity dynamic-array containers are not treated as TOML arrays.

### Pointers, unions, `any`, and graphs

Only an ordinary single pointer `^T` has generic pointer behavior. Marshal follows a non-nil pointer recursively; nil is `Unsupported_Nil` unless omission removed the containing field. Unmarshal requires a matched pointer slot to be nil, allocates `T` with the selected allocator, installs the pointer immediately, and then populates the pointee so every partial allocation remains reachable. Because Reference Odin returns nil for a zero-byte allocation, a zero-sized pointee uses one aligned sentinel byte cast to `^T`; ordinary pointer cleanup frees that sentinel allocation. This preserves non-nil presence for values such as `^struct {}`.

Support only an optional union with exactly one non-nil alternative and an available nil state. A present TOML value always selects the sole non-nil alternative; TOML never synthesizes nil. Marshal rejects a nil optional union unless omitted. Unmarshal requires the matched union to be nil and activates its alternative before recursive population. Multi-alternative and `#no_nil` unions require a custom codec because source-kind selection is otherwise ambiguous.

Marshal recursively unwraps non-nil `any` and applies the dynamic value's normal rules. A nil `any`, or a non-nil `any` that unwraps to an unsupported nil, is an error unless the field itself was omitted. `omitempty` does not recursively inspect a non-nil `any`. Typed unmarshal rejects every `any` destination; it neither synthesizes hidden dynamic owners nor treats a preseeded `any` as a type hint.

Typed marshal borrows application graphs rather than imposing semantic-document ownership rules on them. Repeated acyclic pointers, maps, slices, or dynamic arrays may be encoded independently by value. Track active ancestor container identities and reject recursion cycles; do not reject a merely repeated identity after its earlier traversal has completed.

### Named/distinct and unsupported kinds

After exact codec lookup and the exact temporal checks, named/distinct values inherit supported generic behavior from their underlying boolean, integer, float, string, array, slice, dynamic-array, map, pointer, or struct kind. Named structs bind through their own reflected fields and tags. Type aliases naturally have the aliased `typeid` and behavior.

The generic binder explicitly rejects enums, bit sets, complex and quaternion numbers, matrices, SIMD vectors, SoA pointers and containers, fixed-capacity dynamic arrays, bit fields, `#raw_union` structs, `cstring`, `rawptr`, multi-pointers, relative pointers and slices, procedures, `typeid`, opaque or invalid RTTI states, unsupported unions, and unmarshal destinations of `any`. Raw-union fields overlap and cannot satisfy independent installation or recursive cleanup. Fixed-capacity dynamic arrays have inline storage and do not follow allocator-retaining dynamic-array ownership. Storage layout is never used to reinterpret an unsupported kind. These values need an exact custom codec if issue 12 makes that conversion expressible.

Validate declared map-value and sequence-element types even when their current or source container has no elements. Empty `map[string]Unsupported`, `[0]Unsupported`, `[]Unsupported`, and `[dynamic]Unsupported` values are unsupported without an exact codec rather than conditionally becoming valid while empty.

The complete `toml` package requires normal Odin RTTI because its frozen typed APIs contain `any`. Builds using `ODIN_NO_RTTI` are unsupported even for semantic-only consumers; this package-wide build requirement does not change the semantic-document workflow's data model.

### Unmarshal pipeline and destination state

Typed unmarshal uses three semantic phases after common configuration validation:

1. Strictly parse the complete input into a private temporary semantic tree while retaining private source ranges needed for typed diagnostics.
2. Preflight the complete generic binding without destination mutation: validate root shape, reflected type plans, tags, field collisions, supported kinds, numeric ranges, exact array lengths, unknown fields, depth, checked size arithmetic, and matched destination ownership state.
3. Install values in semantic table insertion order and array index order.

Use only the selected allocator for the temporary tree, source-range sidecars, reflection scratch, and destination allocations. Destroy all temporary semantic and scratch ownership on every return. Input bytes and temporary strings never become destination aliases.

This strengthens issue 08's permitted partial-state contract:

- configuration, parse, generic type/data/range, tag, field-collision, unknown-field, destination-state, depth, and preflight-allocation errors leave the destination unchanged;
- an allocation error during installation may leave earlier commit units installed;
- issue 12 may allow a custom unmarshaler failure to leave its explicitly supplied target partially changed;
- all installed allocations immediately belong to the destination and are never reclaimed by package failure cleanup;
- every not-yet-installed allocation remains package-owned and is cleaned before return.

Before a matched owning slot can be overwritten it must be exactly zero, not merely logically empty: strings and slices must have zero descriptors, maps and pointers must be nil, dynamic arrays must be uninitialized, optional unions must be nil, and reachable owning children in matched fixed arrays or structs must be zero. A zero-length TOML array may bind to a zero slice without allocation. The package never frees pre-existing destination storage. Missing and ignored fields are not inspected or changed.

Commit at the smallest ownership-safe unit. Scalar assignment commits one field/element; an allocated string is fully cloned before assignment; pointer and optional-union storage becomes reachable before descendant installation; and slice/dynamic-array storage becomes reachable before elements. A generic map entry commits only after its key and value are complete unless a successful nested custom unmarshaler transfers opaque ownership first, in which case that success commits the containing entry under design review 002's recursively cleanable partial-entry rule.

### Unknown fields

Unknown fields are ignored by default. `reject_unknown_fields` applies recursively whenever a table binds to a struct and reports the first unknown key in semantic table insertion order. Ignored values have already passed complete strict TOML parsing but cause no destination allocation. Maps have no unknown-field concept, and there is no catch-all flattened map field.

A flattened anonymous struct contributes its effective fields to its parent for matching; a key unknown to that combined projection is unknown at the parent path.

### Typed ownership and caller cleanup

No generic typed destructor is exposed. Successful and partially installed values follow the same recursive caller-cleanup contract with the exact allocator passed to unmarshal:

| Installed kind | Cleanup under an arbitrary-order individually freeing allocator |
| --- | --- |
| boolean, integer, float, temporal | No allocation; zero as needed. |
| string or named string | Delete its backing bytes, then zero the slot. |
| struct | Recursively clean owning fields, then zero those fields. |
| fixed/enumerated array | Recursively clean each owning element. |
| slice | Recursively clean all elements, delete a non-nil backing allocation, then zero. A zero-length slice and a slice of zero-sized elements own no package backing allocation. |
| dynamic array | Recursively clean elements, delete through its retained allocator, then zero. |
| map | Recursively clean owned keys and values, delete through its retained allocator, then zero. |
| pointer | Clean the pointee, free the pointee allocation, then nil the pointer. |
| optional union | Clean the active alternative, then set the union to nil. |

Zero and untouched elements are safe to visit under these generic rules. Map key strings installed by unmarshal are owned. With an externally reclaimed allocator, callers zero or discard owning slots and later reclaim the allocator's complete external lifetime rather than invoking unsupported individual deletion. Ignored and missing fields retain prior application ownership; callers either distinguish them when cleaning only package-installed state or destroy the complete application value according to their broader ownership policy. Issue 12 must define callback-specific cleanup responsibilities.

### Typed diagnostics and precedence

Keep every typed error allocation-free and use an ordinary union with nil as success:

```odin
Unmarshal_Error :: union {
    Unmarshal_Configuration_Error,
    Unmarshal_Parse_Error,
    Unmarshal_Diagnostic,
    runtime.Allocator_Error,
    // Codec failure wrapper added by issue 12.
}
```

`Unmarshal_Configuration_Error` covers a nil allocator procedure, invalid `max_depth`, and a nil destination pointer. `Unmarshal_Parse_Error` preserves the complete strict `Parse_Error`. Typed diagnostic details distinguish unsupported destination type, source/destination kind mismatch, integer range, float range, fixed-array length mismatch, malformed tag, effective field-name collision, unknown field, nonzero destination ownership state, and checked destination-size overflow. They carry the relevant destination `typeid`, source kind or counts, optional source range, and the safest available bounded path under issue 08's borrowing rules. A path must never borrow the destroyed temporary tree; when no stable installed destination or RTTI string can supply a segment, retain the numeric source range instead.

Unmarshal failure precedence is:

1. nil allocator procedure;
2. invalid `max_depth`;
3. nil destination pointer;
4. strict parse error;
5. during preflight, reflected struct-plan errors in declaration order and generic binding errors in table insertion or array index order, with the exact allocator error taking precedence whenever scratch allocation prevents that ordered preflight from continuing;
6. the exact allocator error that prevents installation;
7. codec failure placement finalized by issue 12.

Do not aggregate errors.

Issue 10's `Marshal_Error` gains typed diagnostic details for invalid root shape, unsupported type, unsupported nil, integer or float range, malformed tag, effective field-name collision, unsupported map-key type, converted map-key collision, and active recursion cycle. Typed marshal preflight validates configuration, resolves the root, validates encountered struct plans in declaration order, applies `omitempty`, and then traverses surviving struct fields in declaration order, arrays in index order, and maps in sorted converted-key order. It reports the first canonical-path failure or exact allocator error and performs no writer call until preflight succeeds. Issue 12 inserts codec failures into this preflight without weakening the no-output guarantee.

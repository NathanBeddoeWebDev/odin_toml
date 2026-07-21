# Define deterministic TOML encoding

Type: grilling
Status: resolved
Blocked by: 02, 05, 07, 08

## Question

What canonical, always-valid TOML spelling and traversal rules should encode semantic documents and reflected values, including key quoting, strings, floats, temporals, nested tables, inline tables, arrays-of-tables, insertion/declaration/map ordering, writer failures, and values TOML cannot represent?

## Answer

Use one compact canonical TOML 1.1 profile for both semantic-document unparse and reflection-based marshal. Root entries are key/value lines; every non-root table is an inline table; every array, including one containing only tables, uses ordinary array syntax. The package never reconstructs dotted keys, standard table headers, or array-of-tables headers because issue 07 deliberately discarded the source-definition provenance needed to do so. This profile represents every valid semantic tree without TOML table-definition ordering hazards.

### Public encoding shape and options

Use `Marshal_Options` for the common output policy of both semantic and typed encoding; do not add `Unparse_Options`. This preserves issue 05's three-option-type surface and gives both workflows the same depth contract. Issue 12 may add codec configuration to this type; semantic unparse never consults typed-codec fields.

```odin
Marshal_Options :: struct {
    max_depth: int, // 0 selects 128
    // Per-call codec configuration is added by issue 12.
}

unparse :: proc(
    doc: ^Document,
    options: Marshal_Options = {},
    allocator := context.allocator,
    loc := #caller_location,
) -> (string, Unparse_Error)

unparse_to_writer :: proc(
    writer: io.Writer,
    doc: ^Document,
    options: ^Marshal_Options,
    allocator := context.allocator,
    loc := #caller_location,
) -> Unparse_Error

marshal :: proc(
    value: any,
    options: Marshal_Options = {},
    allocator := context.allocator,
    loc := #caller_location,
) -> ([]byte, Marshal_Error)

marshal_to_writer :: proc(
    writer: io.Writer,
    value: any,
    options: ^Marshal_Options,
    allocator := context.allocator,
    loc := #caller_location,
) -> Marshal_Error
```

Apply `@(require_results)` to all four procedures. A writer options pointer must be non-nil and remain stable for the call; callers use `&Marshal_Options{}` for defaults. `max_depth == 0` selects 128, explicit values may be `1..256`, and 256 is the package hard maximum. Depth has issue 09's semantic definition: the root table is depth zero and each table-key or array-index segment adds one. Reject a child before descending when its next segment exceeds the selected limit.

Semantic encoding accepts only an initialized `^Document`. Typed marshal must produce a TOML root table; issue 11 decides which reflected root kinds do so. It may not wrap a scalar or array in an invented key.

### Exact document and container bytes

Traverse every semantic `Table` in its stored insertion order and every `Array` in element order. Emit each root entry as:

```text
<key> = <value>\n
```

Use exactly one ASCII space on each side of `=` and LF regardless of platform. A non-empty document ends immediately after the final entry's LF and has no extra blank line. An empty root emits zero bytes and causes no writer calls.

Use these exact recursive container forms:

```text
[]
[v1, v2, v3]
{}
{ "k1" = v1, "k2" = v2 }
```

There is one ASCII space after each comma. Non-empty inline tables additionally have one space immediately inside each brace; empty containers have no interior space. Emit no comments, blank lines, indentation, trailing commas, dotted keys, `[table]` headers, or `[[array-of-tables]]` headers. A semantic array whose elements happen to be tables is encoded as an ordinary array of inline tables. An array decoded from `[[x]]` therefore encodes identically to an equivalent array of inline tables, including the empty-array case where no element kind exists.

The canonical traversal orders are:

- semantic tables: retained insertion order, recursively;
- reflected structs: declaration order of the fields selected by issue 11, including recursively nested structs;
- reflected maps: ascending decoded TOML key order after issue 11's key conversion, recursively;
- arrays, slices, and dynamic arrays: element order.

The map-key comparator is lexicographic order over unsigned UTF-8 bytes, with a proper prefix before the longer key. For valid scalar text this is also Unicode-scalar lexicographic order. Do not normalize or case-fold. Converted map keys that compare equal are a collision error; map iteration order never breaks a tie. Field selection, renaming, omission, and flattening remain issue 11 decisions, but surviving struct fields retain declaration traversal order after those rules are applied.

The TOML requirements research recommended sorting all tables as one possible generic policy; this ticket deliberately overrides that recommendation for semantic documents because the map destination and issue 07 require insertion order.

### Keys and strings

Encode every key independently as a single-line basic string, even when it is a legal bare key. Never use dotted-key spelling. Encode every string with the same single-line basic-string procedure. Empty, numeric-looking, dotted, spaced, and Unicode keys therefore need no special cases.

Validate key and string bytes as well-formed UTF-8 scalar text and reject invalid text rather than replacing or repairing it. Preserve scalar sequences exactly without Unicode normalization. Between the quotes:

- `\"` encodes U+0022 and `\\` encodes U+005C;
- `\b`, `\t`, `\n`, `\f`, `\r`, and `\e` encode U+0008, U+0009, U+000A, U+000C, U+000D, and U+001B;
- every other U+0000..U+001F value and U+007F uses `\xHH` with uppercase hexadecimal digits;
- every other valid Unicode scalar is emitted directly as UTF-8.

Never emit literal strings, multiline strings, raw newlines, or `\u`/`\U` escapes. These choices guarantee that string contents cannot add physical output lines and that one semantic scalar sequence has one spelling.

### Scalar spellings

Booleans are exactly `true` and `false`. Integers are minimal base-ten ASCII with a leading `-` only when negative: no `+`, radix prefix, underscores, or leading zeros; zero is `0`. Every `i64` value, including the minimum, is representable.

Format `f64` without delegating canonical-byte policy to a compiler-version-dependent general formatter:

- positive zero is `0.0` and negative zero is `-0.0`;
- positive and negative infinity are `inf` and `-inf`;
- every NaN sign, payload, and signaling/quiet representation becomes `nan`;
- every finite nonzero value uses the shortest correctly rounded decimal significand that parses under round-to-nearest, ties-to-even to the identical binary64 bits;
- when more than one shortest significand round-trips, choose the one numerically closest to the exact binary value, then choose an even final decimal digit on an exact tie;
- form both the minimal fixed candidate and normalized scientific candidate from that significand, removing insignificant decimal zeros;
- scientific notation has one digit before an optional decimal point, lowercase `e`, no `+` on a positive exponent, and no exponent leading zeros;
- append `.0` to a fixed candidate that would otherwise lex as an integer;
- choose the candidate with fewer UTF-8 bytes, using fixed notation when lengths tie, then prepend the sign for a negative finite value.

This rule is algorithm-independent, preserves the distinction between TOML integer and float, and freezes exact bytes across supported Odin revisions. Every finite spelling must parse through this package's strict decoder to the same `f64` bit pattern. Canonical NaN encoding intentionally does not preserve host-only NaN metadata.

Use issue 06's temporal spellings unchanged after `temporal.validate` succeeds:

- local date: `YYYY-MM-DD`;
- local time: `HH:MM:SS[.fraction]`;
- local date-time: date, uppercase `T`, then local time;
- offset date-time: local date-time followed by uppercase `Z` for known zero, `±HH:MM` for another known offset, or `-00:00` for unknown offset.

Seconds are always present. Omit a zero nanosecond fraction; otherwise emit one through nine digits with trailing zeros removed. Preserve second `60` and unknown offset and never infer, normalize, or convert timezone state while encoding.

### Validation and values TOML cannot represent

Perform a complete package-controlled preflight before the first writer call. It validates configuration, source shape, all reachable keys and values, ordering plans, depth, cycles/aliases, and checked encoded-size arithmetic. Scratch needed for deterministic traversal is retained through emission so a built-in data, depth, size, or scratch-allocation error produces no writer output. The source must not be concurrently mutated during either pass.

Semantic unparse rejects, in deterministic traversal order:

- a nil, zero, or otherwise uninitialized document;
- an invalid union state or zero/uninitialized table or array;
- a duplicate exact key in any table;
- invalid UTF-8/non-scalar key or string text;
- an invalid temporal value, retaining the exact `temporal.Error`;
- a cycle;
- repeated or overlapping owned container or non-empty string backing identities that violate issue 08's exclusive-ownership contract, where detectable;
- mixed or mismatched document/container allocator state, where detectable;
- maximum-depth or checked-size overflow.

Every valid `Value` alternative is otherwise representable. All `i64` values and all `f64` bit patterns have canonical output. TOML has no null, missing value, object identity, references, or arbitrary application-value scalar. Typed marshal must therefore return explicit errors rather than emit `null`, stringify an unsupported value, infer a timezone, coerce a scalar kind, invent a root key, or silently omit a value. In particular, nil that was not removed by an issue-11 omission rule is an explicit unsupported-nil error. Issue 11 still decides the supported reflected kinds, exact root-table rules, pointer/union/`any` traversal, map-key conversions, tags, and whether acyclic shared application references encode by value. Active recursion cycles are always rejected. Issue 12 decides codec lookup and callback mechanics.

Custom codecs must not weaken canonical output. Issue 12 must make a marshaler supply a semantic TOML value during preflight; package validation and canonical emission then proceed exactly as for any other value. Unrestricted callback-written TOML text is excluded because it could vary spelling/order, bypass full preflight, or be invalid. Issue 12 retains the callback signature, temporary-value ownership and cleanup, invocation count, error wrapping and precedence, recursion, and re-entrancy decisions.

### Errors, paths, and precedence

Keep errors allocation-free. Use one common bounded encode-diagnostic path for unparse and marshal: string segments borrow semantic document keys, source application strings, or process-lifetime RTTI names; index segments are copied. It uses the same 32-segment first-eight/last-24 truncation policy as `Parse_Diagnostic_Path`, records total and omitted counts, and is invalidated according to issue 08's document/source-borrow rules. The path includes the offending prospective key or index when known and identifies the first error in canonical traversal order.

`Unparse_Error` distinguishes configuration, semantic data, limits, the exact `runtime.Allocator_Error`, and `io.Error`. Its data detail distinguishes at least invalid document/value/container state, invalid text, duplicate key, invalid temporal with `temporal.Error`, cycle, ownership alias, and allocator mismatch. Its limit detail distinguishes maximum depth and size overflow. `Marshal_Error` contains the same common alternatives plus the unsupported-type, unsupported-nil, root-shape, key-conversion/collision, and codec alternatives finalized by issues 11 and 12. A nil error is success. Allocated-return calls never produce an `io.Error`; the shared family retains that alternative for writer calls.

Failure selection is deterministic:

1. nil allocator procedure;
2. nil writer options pointer, then invalid `max_depth`;
3. the first preflight data or limit failure in canonical traversal order, or the exact allocator error that prevents preflight;
4. an output allocation/final-sizing error for allocated-return calls;
5. the first writer error after output begins.

Issue 12 must place codec failures within the preflight phase without changing the no-output guarantee, but owns their exact precedence relative to other typed-marshal failures.

For writer calls, use each writer result exactly once and never retry it. If the writer returns an explicit non-nil error, preserve that exact `io.Error`, even when it also accepted a prefix. A count outside `0..len(requested)` becomes `.Invalid_Write`; a short count with nil error becomes `.Short_Write`. Any bytes already accepted belong to the writer and are not rolled back. Writer errors may therefore leave an arbitrary canonical prefix, while package-owned scratch is cleaned on every return.

### Allocated results and equivalence

`unparse` and `marshal` borrow and never mutate their source. After successful preflight they allocate one exact-length result using only the selected allocator; a non-empty result has no hidden builder capacity. Empty semantic documents and typed empty root tables return nil-backed empty output. On every error they return nil-backed empty output and clean all package-owned scratch under issue 08's individual-free or external-lifetime rules. They never fall back to the ambient allocator.

On success, allocated and writer forms produce byte-for-byte identical output for the same source and options. Re-parsing successful output must produce the same semantic tree, modulo the deliberately canonicalized NaN metadata and the issue-11 fact that typed application identity and representations are not part of TOML semantics.

# Odin TOML 1.1 package design specification

Status: approved design handoff
Reference compiler: Odin `dev-2026-07:2c25fb924` (`2c25fb92420bfa31da62e2194b0cc2cb8bd54cf8`)

This specification is the implementation handoff for the repository-root `toml` package and its reusable sibling `temporal` package. The [wayfinder map](map.md), resolved [issues 01–13](issues/), and [research assets](research/) remain normative for details. If this synthesis appears ambiguous, the resolved ticket governing that topic controls; implementation must not silently choose a different behavior.

## 1. Goal and compatibility contract

The repository will provide:

1. a strict complete-document TOML 1.1 parser into an allocator-owned semantic document tree;
2. deterministic TOML 1.1 serialization from that tree;
3. reflection-based typed marshal and unmarshal workflows;
4. direct `io.Writer` output;
5. caller-owned, per-call exact-`typeid` custom codecs; and
6. an allocation-free sibling `temporal` package for civil and fixed-offset temporal values.

The design follows the installed `core:encoding/json` package where familiarity and allocator explicitness help, but deliberately avoids global codec state, broad helper exposure, permissive parsing, incomplete duplicate checks, mixed allocator destruction, and fragile failure cleanup.

Before 1.0, documented breaking changes are allowed. From 1.0, semantic versioning protects public declarations, ownership contracts, strict TOML 1.1 behavior, and deterministic output bytes. Initial compiler support is exactly the Reference Odin revision. The package requires normal RTTI in every build because its frozen public typed-binding declarations use `any`; `ODIN_NO_RTTI` builds are unsupported, including semantic-only consumers.

## 2. Module architecture and dependency direction

The design has two public modules and no public implementation seams:

```text
application
   ├── imports toml ────────┐
   └── may import temporal  │
                            ▼
                         temporal
```

- `temporal` is a reusable module with transparent allocation-free values, validation, comparison, and explicit `core:time`/`core:time/datetime` conversions.
- `toml` is the repository-root module. Its interface contains semantic-document, typed-binding, writer, lifecycle, direct-table-mutation, and codec-registry procedures.
- `toml` depends on `temporal`; `temporal` never depends on `toml`.
- Lexer, parser definition state, reflection plans, encoder plans, float formatting, diagnostics construction, and allocation tracking are private implementation details inside `toml`, not separate public modules.
- The interface is also the test surface. No tokenizer, parser object, reflected setter, encoder builder, or raw syntax callback is exposed.

## 3. Repository and source-file boundaries

Implementation starts with this layout. A later split or merge may move private declarations without changing the interface, but responsibility must not cross the stated seams.

```text
/
├── README.md
├── LICENSE
├── CONTEXT.md
├── types.odin                  # public scalar aliases, Value, Entry, Table, Array, Document, Path
├── options.odin                # Parse_Options, Marshal_Options, Unmarshal_Options, limits
├── errors.odin                 # public allocation-free error and diagnostic declarations
├── document.odin               # clone/destroy/get/set/remove and tree validation entry points
├── lexer.odin                  # private allocation-free pull lexer and UTF-8/source tracking
├── parser.odin                 # public parse procedures and private recursive-descent parser
├── parser_state.odin           # private table-definition graph, lookup state, AoT latest-element state
├── temporal_toml.odin          # private TOML temporal recognition, normalization, and formatting
├── encode.odin                 # private common canonical preflight/plan/emission engine
├── float_format.odin           # private canonical binary64 decimal implementation
├── unparse.odin                # semantic document allocated/writer entry points
├── reflect_plan.odin           # private RTTI traversal, tags, field/map/sequence plans
├── marshal.odin                # typed encode entry points and source binding
├── unmarshal.odin              # typed decode pipeline and destination installation
├── codecs.odin                 # public registry lifecycle plus private lookup/invocation
├── temporal/
│   ├── types.odin              # temporal public value and Error declarations
│   ├── validate.odin           # validate overloads and Gregorian/component checks
│   ├── compare.odin            # civil and instant comparison
│   ├── convert.odin            # explicit core:time and datetime interoperability
│   └── temporal_test.odin
├── tests/
│   ├── support/                # test-only equality, tracking/fail allocators, writer, generators
│   ├── fixtures/               # focused local TOML and regression fixtures
│   ├── oracle/                 # pinned test-only Ryu source/provenance; never runtime code
│   └── corpus/                 # pin/provenance/report tooling, not a mutable vendored corpus
├── cmd/
│   ├── toml_test_decoder/      # test-only tagged-JSON decoder adapter
│   └── toml_test_encoder/      # test-only tagged-JSON encoder adapter
└── .github/workflows/          # supported target/mode/conformance/fuzz jobs
```

Public declarations are limited to the interface named in this specification and resolved tickets. Every other declaration is marked `@(private)`. Package tests may be colocated as `*_test.odin` where Odin package visibility requires it; `tests/` holds test support and fixtures, not a third public library.

Implementation dependency flow inside `toml` is:

```text
parse entry points → UTF-8 preflight → lexer → parser + parser_state → Document
Document → common semantic validator/encode plan → emitter → string or writer
application value → reflect_plan + codecs → common semantic encode plan → bytes or writer
input → strict private parse with ranges → reflect_plan preflight → destination installation
```

The common canonical encoder is the sole implementation of TOML spelling. Typed marshal and semantic unparse must not develop separate formatting rules.

## 4. Public interface sketch

The sketch fixes names, workflow shape, allocator placement, and ownership. The exhaustive [public interface freeze](public-interface-freeze.md) fixes every error alternative/payload, temporal conversion name, registry representation, callback declaration, nil-success rule, attribute, and diagnostic lifetime. Stage 0 may adjust only Reference-Odin syntax while transcribing it.

```odin
package toml

import "core:io"
import "core:mem"
import "base:runtime"
import temporal "project:temporal" // collection spelling selected by repository build setup

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
    root:      Table,
    allocator: mem.Allocator,
}

Path_Index :: distinct int
Path_Segment :: union #no_nil {String, Path_Index}
Path :: distinct []Path_Segment

Parse_Options :: struct {
    max_depth: int,
}

Marshal_Options :: struct {
    max_depth: int,
    codecs:    ^Codec_Registry,
}

Unmarshal_Options :: struct {
    max_depth:             int,
    reject_unknown_fields: bool,
    codecs:                ^Codec_Registry,
}

parse :: proc {parse_bytes, parse_string}

parse_bytes :: proc(
    input: []byte,
    options: Parse_Options = {},
    allocator := context.allocator,
    loc := #caller_location,
) -> (Document, Parse_Error)

parse_string :: proc(
    input: string,
    options: Parse_Options = {},
    allocator := context.allocator,
    loc := #caller_location,
) -> (Document, Parse_Error)

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

unmarshal :: proc(
    input: []byte,
    destination: ^$T,
    options: Unmarshal_Options = {},
    allocator := context.allocator,
    loc := #caller_location,
) -> Unmarshal_Error

unmarshal_string :: proc(
    input: string,
    destination: ^$T,
    options: Unmarshal_Options = {},
    allocator := context.allocator,
    loc := #caller_location,
) -> Unmarshal_Error

clone_document   :: proc(doc: ^Document, allocator := context.allocator, loc := #caller_location) -> (Document, Clone_Error)
destroy_document :: proc(doc: ^Document, loc := #caller_location)
clone_value      :: proc(value: ^Value, allocator := context.allocator, loc := #caller_location) -> (Value, Clone_Error)
destroy_value    :: proc(value: ^Value, allocator: mem.Allocator, loc := #caller_location)

get    :: proc(table: ^Table, key: string) -> (^Value, bool)
set    :: proc(table: ^Table, key: string, value: ^Value, loc := #caller_location) -> Mutation_Error
remove :: proc(table: ^Table, key: string, loc := #caller_location) -> bool
```

All fallible public procedures use `@(require_results)`. There are no `encode`/`decode` aliases, filesystem helpers, streaming readers, builder entry points, path mutation, builders, iterators, public validators, or package-global codec registration.

`max_depth == 0` selects 128. Explicit values are `1..256`; 256 is the hard maximum. Depth is semantic path length: root table depth zero; each table key or array index adds one. A child beyond the selected limit is rejected before allocation or installation.

Direct `set` has no root/path argument and therefore cannot know a target table's document-relative depth. It validates the cloned key plus value subtree against the package hard maximum using the target table as local depth zero. A successful nested `set` can consequently make its enclosing document exceed a later operation's selected document-relative limit; `clone_document`, `unparse`, and typed/parse operations enforce their own root-relative limit. This is not a malformed ownership tree, but it is not encodable under that selected limit. Adding document/path-aware mutation is deferred rather than pretending the direct-table interface can enforce unavailable root context.

No public builder or constructor is added. `parse_string("")` is the canonical package operation for obtaining an initialized empty `Document`. Transparent standalone tables and arrays, including codec-produced containers, are initialized with ordinary fallible Odin `make` using their intended owner allocator; every inserted key/string/value must then follow the clone/ownership rules here. Package examples must show the exact Reference Odin recipes and error checks. A caller that does not want to perform those low-level steps starts from an empty parsed document and uses `set`.

## 5. Temporal interface

```odin
package temporal

Local_Date :: struct {
    year:  u16,
    month: u8,
    day:   u8,
}

Local_Time :: struct {
    hour:       u8,
    minute:     u8,
    second:     u8,
    nanosecond: u32,
}

Local_Date_Time :: struct {
    date: Local_Date,
    time: Local_Time,
}

Offset_Kind :: enum u8 {Known, Unknown}

UTC_Offset :: struct {
    kind:    Offset_Kind,
    minutes: i16,
}

Offset_Date_Time :: struct {
    local:  Local_Date_Time,
    offset: UTC_Offset,
}
```

`temporal.validate` overloads all five public structs. Values are transparent and caller-constructible, so every consuming operation validates them. Invariants are:

- year `0000..9999`, month `1..12`, and valid proleptic-Gregorian day;
- hour `0..23`, minute `0..59`, second `0..60`;
- nanosecond `0..<1_000_000_000`, including a local guard against the Reference Odin `1_000_000_000` validator edge;
- known offset minutes `-1439..1439`;
- unknown offset has minutes zero and preserves RFC 3339 `-00:00`.

The allocation-free `temporal.Error` alternatives are exactly those in issue 06. Civil `compare` overloads return `-1/0/+1` plus `Error`. `compare_instant` applies known numeric displacement; unknown offset behaves numerically as zero without losing its stored state. A leap second with differing offsets returns `.Leap_Second_Not_Comparable`.

Only explicit `core:time`/`datetime` conversions are exposed. They reject loss, unsupported leap seconds, range overflow, and non-local `datetime.DateTime`; they never consult machine timezone state or invent a missing date, time, or offset.

TOML owns text parsing and formatting. Fractions are represented to nanoseconds; source digits after nine are truncated, never rounded. Syntax trivia and original precision are not retained.

## 6. Semantic document model

A successful document is an initialized, allocator-owned root `Table`. The closed, no-null value set is exactly the `Value` union above.

### Table and array invariants

- Each table has one authoritative insertion-ordered entry sequence. Keys are unique exact decoded strings.
- Keys and strings are valid UTF-8 Unicode scalar text, with no normalization or case folding.
- Arrays are ordered and heterogeneous.
- An array of tables is structurally an `Array` containing `Table` values; no provenance flag survives parsing.
- All package-produced containers, including empty containers, are initialized.
- Package-produced trees are acyclic, exclusively owned, and uniform-allocation.
- A zero `Document`, zero table, or zero dynamic array is not a valid initialized semantic owner.

Insertion order is assigned when an entry first comes into semantic existence. Later legal table definition/population does not move it. Replacing with `set` preserves position; inserting appends; `remove` stably compacts; remove then reinsert appends. Clone preserves all table and array order.

Paths contain decoded exact key and array-index segments. Dots in key segments are data. Paths are diagnostic/traversal descriptions, not TOML dotted-key strings.

Direct container manipulation is possible because the representation is transparent, but uniqueness and ownership are guaranteed only for package-produced trees and sanctioned operations. Encoding and cloning validate caller-constructed trees and reject malformed state rather than trusting it.

## 7. Allocation, ownership, borrowing, and cleanup

Every allocating owner-producing call takes an explicit allocator defaulting to `context.allocator` and forwards caller location. A nil allocator procedure is rejected before allocation. No implementation path may fall back to ambient allocation after an explicit allocator has been selected.

### Ownership table

| Value or operation | Owner after success | Borrow/invalidation | Failure guarantee | Release |
| --- | --- | --- | --- | --- |
| `parse_*` result | caller owns `Document` | input borrowed only for call | zero document; all partial tree/scratch cleaned | `destroy_document` |
| `clone_document` | caller owns independent document | source borrowed/unchanged | zero result; partial clone cleaned | `destroy_document` |
| `clone_value` | caller owns independent value under selected allocator | source borrowed/unchanged | zero result; partial clone cleaned | `destroy_value(value, same allocator)` |
| `get` result | no transfer; borrowed `^Value` | invalidated by structural mutation/destruction of containing table; descendant mutation follows descendant rules | absence only | never destroy borrowed pointer |
| successful `set` | table owns deep clones | key/value inputs remain caller-owned | table physically and semantically unchanged | table/document destruction |
| successful `remove` | no returned owner; removed key/value destroyed | table borrows invalidated | no allocation; absence is `false` | internal through table allocator |
| `unparse` result | caller owns exact-length non-empty string | source borrowed/unchanged | nil-backed empty output; scratch cleaned | delete with selected allocator if it supports individual free, otherwise external lifetime |
| `marshal` result | caller owns exact-length non-empty bytes | application source borrowed/unchanged | nil-backed empty output; scratch and codec values cleaned | same rule as `unparse` |
| writer output | writer owns accepted prefix | writer/source/options/registry borrowed for call | package scratch cleaned; emitted prefix not rolled back | writer policy |
| `unmarshal*` destination installations | destination/application owns each committed allocation immediately | input never installed by alias | preflight failures unchanged; installation allocation failure may leave cleanable committed prefix | application recursively cleans with same allocator |
| codec registry | caller owns map storage | borrowed by typed call; frozen during borrow | failed registration leaves prior entries valid | `destroy_codec_registry` |
| custom marshaler result | package owns successful temporary `Value` until encode returns | callback source/user data borrowed | callback cleans on callback error; package cleans successful temporary on every later return | package `destroy_value` with callback allocator |
| custom unmarshaler installation | destination owns on callback success | source `^Value` borrowed only for callback | callback error restores its entire slot to exact zero; earlier unrelated commits may remain | application codec-specific cleanup |

A successful non-empty allocated encoder result has allocation size exactly equal to returned length. Empty success has nil backing and owns no allocation.

`destroy_document` uses the stored allocator, logically destroys all descendants, invalidates borrows, and zeros the document; repeated destruction is a no-op. `destroy_value` requires the same allocator used to create/clone the standalone value. Destruction never calls `.Free_All`. Individually freeing allocators must support arbitrary-order free. For externally reclaimed allocators, destruction logically zeros values and physical storage remains until the caller resets/destroys the allocator lifetime, following issue 08's allocator-feature and `.Mode_Not_Implemented` rules.

Destroy and destructive mutation procedures require either a zero owner or a valid acyclic, exclusively owned, allocator-consistent owner. They are not salvage operations for caller-created cycles, repeated backing aliases, or mixed allocators: attempting to destroy such malformed ownership is a caller contract violation and could otherwise recurse or free twice. When validation rejects a malformed caller tree, the caller must repair ownership first or reclaim the complete external allocator lifetime. Package-produced owners and sanctioned operations always satisfy the destroy precondition.

No generic typed destructor exists. Caller cleanup for package-installed typed values is recursive:

- scalars/temporals: no allocation;
- strings: delete bytes, then zero;
- structs/fixed arrays: clean owning children;
- slices: clean elements, delete non-nil backing storage where owned, then zero;
- dynamic arrays: clean elements, delete through retained allocator, then zero;
- maps: clean owned keys and values, delete through retained allocator, then zero;
- pointers: clean pointee, free allocation (including zero-size sentinel), then nil;
- optional unions: clean active alternative, then set nil.

With an external-lifetime allocator, callers zero/discard owning slots and reclaim the allocator lifetime instead of invoking unsupported individual deletion.

A completely zero projected destination is the only generally safe setup when the caller intends to apply that recursive cleanup mechanically after partial unmarshal. The interface intentionally permits pre-existing ownership in missing or ignored fields and does not inspect it; callers using that flexibility must retain application-specific provenance and must not indiscriminately free those fields with the unmarshal allocator. The package returns no installation ledger and cannot infer one safely. Recommended examples therefore use either a wholly zero destination, a dedicated external-lifetime allocator for the decode, or an application destructor that already knows each field's ownership.

## 8. Strict parser contract

`parse_bytes` and `parse_string` consume complete documents and have identical semantics. Empty, whitespace-only, and comment-only input succeeds with an initialized empty root.

Pipeline and precedence:

1. reject nil allocator;
2. validate options;
3. perform allocation-free whole-input RFC 3629 UTF-8 scalar preflight;
4. initialize root and private parser state;
5. lazily lex and recursively parse while applying stateful definition transitions;
6. require expression termination and EOF;
7. discard transient lookup/provenance state and transfer the document owner.

The lexer is private, pull-based, allocation-free, and bounded-lookahead. Tokens and source lexemes borrow input only during the call. It accepts only TOML TAB/SPACE whitespace and LF/CRLF newline. It rejects bare CR, BOM, non-TOML whitespace, invalid comments, forbidden controls, unknown escapes, malformed UTF-8, and scalar-prefix attacks. String/key output is independently allocated, never an input alias. Raw multiline newlines normalize to target convention as allowed by TOML; escaped newline characters preserve their explicit meaning.

Integers use checked accumulation into `i64`, including its minimum. Finite floats convert to correctly rounded `f64`; signed zero, subnormal, and signed underflow are preserved. A finite literal converting to infinity is rejected. Explicit infinities are accepted. All TOML NaN spellings normalize to one host quiet NaN.

Temporal decoding follows section 5: four distinct kinds, validated components, `T`/`t`/space equivalence, `Z`/`z`/known-zero normalization, preserved unknown `-00:00`, omitted seconds as zero, fraction-without-seconds rejection, leap second preservation, and truncation after nine fractional digits. Acceptance of second `60` is intentionally structural: TOML's released grammar admits it, while this package does not ship an IERS announcement history and therefore does not claim a given civil date was historically an announced leap second. This is the explicit issue-06 decision and controls over the earlier research recommendation to validate historical placement; changing it requires reopening the temporal contract rather than an implementation-side restriction.

After scanning one complete scalar candidate through a legal TOML delimiter, value-error classification is deterministic: candidates beginning with `true` or `false` are boolean candidates; candidates with a date prefix `DIGIT{4}-DIGIT{2}-DIGIT{2}` or local-time prefix `DIGIT{2}:DIGIT{2}` are temporal candidates; candidates beginning with `0x`, `0o`, or `0b`—or a sign immediately followed by one of those prefixes—are integer candidates before inspecting their digits (the validator then rejects signed radix forms); remaining numeric candidates containing a decimal point or decimal exponent, or beginning with an allowed `inf`/`nan` spelling prefix, are float candidates; other candidates beginning with a sign or decimal digit are integer candidates; everything else is `.Invalid_Value`. The selected category validates the complete candidate, so `truex` is `.Invalid_Boolean`, `01` and `0x1E3` are integer candidates, `0xG` is `.Invalid_Integer`, `1e+` is `.Invalid_Float`, and a temporal-shaped value with invalid components or suffix is `.Invalid_Temporal`. Lexical failures discovered before a complete candidate exists retain lexical precedence.

### Definition state

The parser maintains private state for root, implicit tables, standard-header tables, dotted-defined tables, sealed inline trees, scalars/static arrays, arrays-of-tables containers, each AoT element, and each container's latest element. It uses stable private IDs rather than pointers into resizable semantic storage. Concretely, the sidecar is an allocator-owned descriptor vector. Each descriptor records its parent node ID plus a stable table-entry index or array-element index; root has a distinguished ID. Parsing only appends semantic entries/elements, so these indexes remain stable even when backing allocations move. Any semantic access resolves the bounded ancestor chain from root and holds no pointer across a fallible append. Lookup maps store node IDs, and all descriptors/maps are discarded after success.

It must enforce decoded-path duplicate and transition rules from TOML prose, not ABNF alone. In particular:

- legal late definition of an implicit parent;
- no repeated standard table;
- no later header redefinition of a dotted-defined table;
- no traversal through scalar/static array/sealed inline table;
- no extension outside an inline table's isolated scope;
- no normal-table/static-array/AoT kind reuse;
- each `[[path]]` resolves afresh from root and crosses parent AoTs through their latest elements;
- nested AoT children cannot precede the parent element they attach to.

All parser mutation is unpublished until success. Any error destroys the entire partial document, unattached owners, and sidecars.

## 9. Diagnostics and error model

All errors are values, allocation-free, require no destructor, and use a nil union state for success. The public families are:

- `Parse_Error`: configuration, source encoding/lexical/grammar/value/definition/limit diagnostic, or exact allocator error;
- `Clone_Error`: invalid semantic data/ownership/depth or exact allocator error;
- `Mutation_Error`: invalid/uninitialized table, invalid key/value/ownership/depth, or exact allocator error;
- `Unparse_Error`: configuration, semantic data, limit, exact allocator error, or `io.Error` for writer forms;
- `Marshal_Error`: unparse/common alternatives plus root/type/nil/conversion/tag/map/cycle/codec diagnostics;
- `Unmarshal_Error`: configuration, wrapped complete parse error, typed/tag/range/unknown-field/destination-state/codec diagnostics, or exact allocator error;
- `Codec_Registry_Error`: invalid allocator/registry/type/callback, duplicate directional codec, or exact allocator error.

The exact parse declarations, detail alternatives, and failure order are frozen by issue 09. The [public interface freeze](public-interface-freeze.md) closes the declaration choices that issues 10–12 described conceptually. Implementers may group declarations in `errors.odin`, but may not add/collapse documented categories, rename public alternatives, or replace exact external errors with generic failures without reopening this design.

Source coordinates are zero-based UTF-8 byte offset, one-based line, and one-based Unicode-scalar column. Ranges are half-open in original source coordinates; EOF expectations use an empty range. Byte offsets are authoritative for slicing retained input. Parse and unmarshal errors never borrow source input.

Malformed UTF-8 diagnoses the leading byte of the first ill-formed sequence with the exact one-byte range policy in issue 09. Definition errors carry the attempted primary range and the prior conflicting definition as `related` when applicable.

Parse paths are bounded owned snapshots:

- capacity 32 segments, with all segments when they fit;
- otherwise first 8 and final 24 plus exact omission counts;
- key snapshot capacity 64 decoded bytes;
- longer keys retain the longest valid UTF-8 prefix at/before 32 and suffix at/after the final 32-byte boundary, plus source byte range and exact truncation metadata.

Encode diagnostic paths use the same segment truncation policy, copy indexes, and borrow safe key/name strings from the document, application value, destination, or process-lifetime RTTI. Their lifetime ends when that source storage is mutated, moved, cleaned, or destroyed as detailed in issue 08.

## 10. Deterministic semantic encoding

Semantic unparse and typed marshal use one compact canonical profile:

```text
"root-key" = value\n
[]
[v1, v2, v3]
{}
{ "k1" = v1, "k2" = v2 }
```

- Every root entry is `<quoted-key> = <value>\n`.
- Empty root emits zero bytes and makes zero writer calls.
- Non-root tables are always inline tables.
- Every array, including tables-only arrays, uses ordinary array syntax.
- Non-empty containers use one space after commas; non-empty inline tables have one interior space at both braces.
- There are no comments, headers, dotted keys, indentation, blank lines, or trailing commas.
- Output newlines are always LF on every target.

Traversal order is semantic table insertion order, reflected struct declaration/flatten-expansion order, array order, and reflected map order sorted lexicographically by unsigned UTF-8 bytes after key conversion. Equal converted map keys are an error.

Every key and string uses one-line basic-string spelling. Quote and backslash use `\"` and `\\`; named escapes cover backspace, tab, LF, form feed, CR, and escape; other C0/DEL controls use uppercase `\xHH`; all other valid Unicode scalars emit directly. Invalid scalar text is rejected.

Scalar spellings are:

- booleans `true`/`false`;
- minimal base-ten integers with only a negative sign when needed;
- float zero `0.0`/`-0.0`, infinities `inf`/`-inf`, every NaN as `nan`;
- finite nonzero binary64 uses issue 10's shortest correctly rounded decimal, fixed/scientific candidate, tie, exponent, and integer-looking `.0` rules;
- temporals use fixed-width canonical forms with uppercase `T`, uppercase `Z` for known UTC, explicit numeric known offsets, `-00:00` for unknown offset, seconds always, and nonzero nanoseconds with trailing zeros removed.

Encoding performs complete package-controlled preflight before the first writer call. It validates configuration, source/root shape, UTF-8, temporals, duplicate keys, initialized containers, depth, checked size, cycles, and detectable ownership aliases/allocator mismatches. Typed preflight additionally plans tags/fields/map keys, resolves codecs exactly once, and retains codec-produced semantic values through emission.

Writer calls are non-transactional only after successful preflight. Each result is consumed once and never retried. Explicit writer errors are preserved even with accepted bytes; out-of-range counts become `.Invalid_Write`; short count with nil error becomes `.Short_Write`. Accepted bytes are an arbitrary canonical prefix owned by the writer. Allocated and writer forms are byte-identical on success.

## 11. Typed binding

Typed roots represent TOML's root table. After exact codec lookup and non-nil wrapper resolution, generic marshal roots must be struct or eligible map; generic unmarshal destination types must be struct or eligible map. Generic scalar, temporal, and sequence roots are rejected. `Document`, `Table`, and `Value` remain semantic-document types rather than typed-binding shortcuts.

Binding is closed and same-category:

| TOML kind | Odin destination/source | Rule |
| --- | --- | --- |
| string | `string` and named/distinct string | validate; unmarshal clones |
| boolean | `bool` and named/distinct bool | no coercion |
| integer | signed/unsigned integer kinds and named/distinct forms | checked exact fit to destination; marshal must fit `i64` |
| float | `f16`, `f32`, `f64` and named/distinct forms | marshal widens; unmarshal rounds narrower, allows precision loss/underflow, rejects finite overflow |
| each temporal kind | exact matching `temporal` type only | validate; no wrapper or time/string conversion |
| array | fixed/enumerated array, slice, dynamic array | elementwise; exact fixed length |
| table | struct or eligible map | projected fields or string keys |

There is no integer/float crossover, enum/bit-set conversion, stringification, temporal inference, or union-by-source-kind inference.

### Struct projection and tags

- Untagged ordinary field name is the exact case-sensitive TOML key.
- Named `using` is an ordinary named field.
- Anonymous `using _: Struct` recursively flattens at its declaration position.
- A flattened wrapper permits only absent/empty tag or `toml:"-"`; rename/`omitempty` on the wrapper is invalid.
- `toml:"-"` ignores the complete field/subtree in both directions.
- Effective names after flattening/renaming must be unique; no precedence winner exists.
- Every selected destination field type is validated even when source key is absent.
- Missing fields remain unchanged; there is no required-field mode.

The only tag grammar is `toml:"[name][,omitempty]"` or `toml:"-"`. Empty name uses the Odin field name. Names are literal decoded keys; dots do not form paths. Validate the complete raw tag list, reject malformed syntax and duplicate `toml` entries, then reject unknown/duplicate/empty/trailing/whitespace-padded options. Commas cannot be represented in a tag name.

`omitempty` applies only to marshal and before codec lookup/value traversal. It omits false, numeric zero including either float signed zero, zero-length string, zero-length array/slice/dynamic array/map, nil ordinary pointer, nil optional union, and genuinely nil `any`. Structs and temporals are never empty; non-nil wrappers are not recursively empty.

### Containers and wrappers

- Generic map keys are only string or named/distinct string; codecs never apply to map keys.
- Map output sorts converted keys; map unmarshal requires a nil map and commits complete key/value pairs in semantic insertion order.
- Fixed/enumerated arrays require exact length. Slices and dynamic arrays install storage before elements and commit elements in order.
- A nil slice may represent an empty array; a nil dynamic array/map is unsupported unless omitted.
- Ordinary `^T` pointers are supported; nil marshal is an error unless omitted. Unmarshal requires nil and installs pointee storage before descendants. Zero-size pointees receive a one-byte aligned sentinel allocation.
- Only optional unions with exactly one non-nil alternative and a nil state are generic. Present TOML activates that alternative; TOML never synthesizes nil.
- Marshal recursively unwraps non-nil `any`; unmarshal destination `any` is unsupported.
- Repeated acyclic application references encode by value; active recursion cycles fail.

All unsupported kinds listed in issue 11 require an exact codec or fail explicitly. Declared container element/map-value types are validated even when the container is empty.

### Unmarshal phases

1. Strictly parse complete input to a temporary semantic tree with source ranges.
2. Preflight the complete generic binding without destination mutation: root, plans/tags, kinds, ranges, lengths, unknown fields, depth, checked sizes, and matched destination zero ownership.
3. Install in semantic table insertion and array index order.

Configuration, parse, type/data/tag/unknown/destination/depth, and preflight allocation failures leave the destination unchanged. Installation allocation failure may leave earlier ownership-safe commit units installed. The package cleans all uninstalled state; the caller cleans installed partial state with the selected allocator.

Matched owning slots must be exactly clean/zero. Missing and ignored fields are neither inspected nor changed. Unknown struct fields are ignored by default and rejected recursively in insertion order when `reject_unknown_fields` is true; maps have no unknown-field concept.

## 12. Custom codec registry

The public registry interface is:

```odin
Codec_Registry :: struct { /* owner of two exact-typeid maps and allocator metadata */ }

Codec_Marshaler :: struct {
    procedure: Codec_Marshal_Proc,
    user_data: rawptr,
}

Codec_Unmarshaler :: struct {
    procedure: Codec_Unmarshal_Proc,
    user_data: rawptr,
}

Codec_Callback_Failure :: struct {code: u32}
Codec_Callback_Error :: union {Codec_Callback_Failure, runtime.Allocator_Error}

Codec_Marshal_Proc :: #type proc(
    source: any,
    user_data: rawptr,
    allocator: mem.Allocator,
    loc: runtime.Source_Code_Location,
) -> (Value, Codec_Callback_Error)

Codec_Unmarshal_Proc :: #type proc(
    source: ^Value,
    destination: any,
    user_data: rawptr,
    allocator: mem.Allocator,
    loc: runtime.Source_Code_Location,
) -> Codec_Callback_Error

init_codec_registry :: proc(allocator := context.allocator, loc := #caller_location) -> (Codec_Registry, Codec_Registry_Error)
destroy_codec_registry :: proc(registry: ^Codec_Registry, loc := #caller_location)
register_marshaler :: proc(registry: ^Codec_Registry, id: typeid, marshaler: Codec_Marshaler, loc := #caller_location) -> Codec_Registry_Error
register_unmarshaler :: proc(registry: ^Codec_Registry, id: typeid, unmarshaler: Codec_Unmarshaler, loc := #caller_location) -> Codec_Registry_Error
```

The registry is caller-owned, per-call, exact-`typeid`, directional, and contains no global state. Duplicate registration in one direction fails; marshal and unmarshal registration for the same type may coexist. Registry storage uses its recorded allocator; `user_data` and callback code remain application-owned. Frozen registry reads may be concurrent; registration/destruction during a TOML call is a caller violation.

Lookup occurs before named-type unwrapping and generic/temporal rules at each typed node. `omitempty` occurs before lookup. Map keys never consult codecs. Wrapper codecs can target exact pointer/optional types; otherwise generic wrapper traversal exposes the child for another exact lookup.

A custom marshaler runs exactly once per encountered node during preflight and returns a semantic `Value`, never raw TOML. It must allocate all escaping ownership with the supplied allocator, transfer only a complete valid owner on success, and return zero/no partial owner on error. TOML caches, validates, canonically emits, and always destroys successful codec values.

A custom unmarshaler receives a borrowed semantic value and an exact clean destination slot. On failure it must clean all work and restore the entire supplied slot to exact zero. On success installed storage belongs to the destination and follows the application type's codec-specific cleanup contract. This issue-12 rule explicitly supersedes issue 08's earlier provisional allowance for a callback to leave its own target partially changed; only earlier, separate generic commit units may remain installed.

Callbacks cannot retain borrows, mutate marshal sources/semantic inputs, call active typed TOML operations recursively, or access parser/writer state. Callback-defined failure codes are nonzero and wrapped with package path/type/range; callback allocator errors propagate as exact allocator errors.

## 13. Validation and conformance criteria

Implementation acceptance is exactly issue 13. In summary, all of these are mandatory release gates:

1. **Official corpus:** `toml-lang/toml-test` v2.2.0 at `ce08da1ddb075d1c7596d663c7fcba9a2ae02c5c`, invoked with literal `-toml=1.1.0`; separate public-interface decoder/encoder adapters; zero valid, invalid, or encoder failures and zero skips; preserved JSON report and MIT provenance.
2. **Focused parser/temporal tests:** lexical, UTF-8, strings/escapes, numbers, all definition transitions, AoT latest binding, all temporal boundaries, depth, and complete-input behavior with nearest valid neighbors.
3. **Diagnostics:** every package alternative/detail, exact precedence, ranges/coordinates, related definitions, path/key truncation, and post-input-lifetime validity.
4. **Semantic/lifecycle tests:** initialized versus zero owners, clone/destroy, get/set/remove, order, borrow invalidation, malformed caller trees, aliases/cycles, and allocator mismatch.
5. **Exact encoder goldens:** every canonical byte rule, all order policies, all scalar edges, temporal spellings, float output against pinned Ryu `4c0618b0e44f7ef027ebae05d2cc7812048f7c8f`, and platform-independent LF.
6. **Properties:** semantic/text/canonical round trips, allocated/writer identity, clone independence, repeated determinism, typed represented-value round trips, and paired codecs.
7. **Reflection/codec matrices:** every supported/rejected kind, tags/flattening/omit, destination state, partial commits, exact registry behavior, callback order, ownership, and concurrency.
8. **Allocator gates:** fail-at-N sweeps over every allocating phase, tracking allocator, default heap, external-lifetime arenas, no ambient fallback, exact allocator errors, and cleanup of typed partial state.
9. **Writer gates:** every call ordinal and count/error combination, exact prefix, no retries, no preflight writes, and cleanup.
10. **Fuzz/robustness:** deterministic in-suite budgets (4,096 arbitrary byte cases and 2,048 valid-seed mutations), replayable seeds, coverage-guided targets, sanitizer-backed 300-second aggregate PR smoke, and regression fixtures for every minimized finding.
11. **Platform/mode:** complete local suite on Linux amd64/arm64, macOS amd64/arm64, and Windows amd64; normal strict-vet/style/warnings and `-o:speed`; bad-memory checks; ASan where supported; immutable-registry TSan stress; conformance at least Linux amd64 and wherever semantics differ.

There is no initial coverage percentage or performance threshold. Green conformance alone is insufficient. A release candidate must contain the complete evidence bundle specified in issue 13.

## 14. Non-goals

The initial package does not provide:

- CST/lossless editing or retention of comments, whitespace, source order trivia, quote/radix/separator style, or exact fractional digit count;
- filesystem convenience APIs or streaming `io.Reader` decoding;
- permissive, recovery, duplicate-accepting, UTF-8 replacement, TOML 1.0, legacy, or extension modes;
- schema validation, configuration merging, environment expansion, or defaulting;
- public tokenizers, parser state, builders, iterators, reflected setters, path mutation, or standalone validators;
- table headers/dotted keys/AoT headers in canonical output;
- timezone database lookup, machine-local inference, broad temporal parsing/formatting, or calendar arithmetic;
- map-key codecs, raw TOML codec output, package-global registration, or callback re-entry helpers;
- generic typed destination destruction;
- compatibility promises for untested Odin revisions or targets;
- an initial benchmark pass/fail threshold.

## 15. Risks and mitigation

| Risk | Consequence | Mitigation / stage that burns it down |
| --- | --- | --- |
| Odin RTTI cannot provide ownership-safe generic assignment | leaks, overwrite, invalid frees | Stage 1 compile probes; Stage 7 zero-state preflight and commit-unit tests |
| Allocator capabilities and externally reclaimed storage vary | leaks or invalid/out-of-order frees | Stage 2 lifecycle spike; feature-reporting and `.Mode_Not_Implemented` tests; no `.Free_All` |
| Stateful dotted/header/inline/AoT rules are easy to mis-model | false acceptance/rejection | Stage 4 sidecar graph with stable IDs; focused transitions before typed work; official corpus in Stage 9 |
| Canonical shortest binary64 formatting is subtle | unstable or non-round-tripping bytes | Stage 3 isolated implementation and Ryu oracle before full encoder |
| Full preflight plus codec caching increases scratch ownership complexity | writes before failure or leaked callback values | Stage 6 encode-plan ownership ledger; fail-at-N and writer tests before typed unmarshal |
| Transparent semantic containers permit malformed aliases/mixed allocators | cycles, double frees, invalid output | validated lifecycle/encode entry points; explicit sanctioned-mutation contract; malformed-graph tests |
| Typed unmarshal partial installation burdens callers | hard cleanup after OOM | three-phase pipeline, exact zero ownership preflight, smallest safe commit units, documented cleanup table |
| Allocation-free bounded diagnostics can truncate context | reduced readability | exact first/last snapshot and omission metadata; authoritative source ranges; exhaustive truncation tests |
| Inline-only canonical output can be large and less human-oriented | usability/performance concern | intentional deterministic semantic profile; benchmark and size baselines after correctness; no alternate profile before evidence |
| Required five-platform/sanitizer/fuzz matrix is expensive | delayed release feedback | stage CI tiers early; fast deterministic suite on every change, expensive mandatory gates scheduled/RC without becoming optional |
| Exact Reference Odin support can drift | build breakage or behavior change | pin compiler in CI; update only through reviewed compatibility work and full acceptance rerun |

No unresolved TOML/Odin impedance mismatch requires a separate prototype before implementation. The highest-risk assumptions are isolated as compile/lifecycle/float probes in the first three stages; failure of one is a design escalation, not permission to weaken a resolved contract silently.

## 16. Staged implementation plan

Each stage ends with runnable evidence and must preserve all earlier gates. Stages are dependency-ordered, not estimates.

### Stage 0 — Repository and reproducibility scaffold

Deliver:

- initialize package/build/test commands for root `toml` and sibling `temporal`;
- compile-probe and freeze the exact root-to-sibling import spelling;
- transcribe the exhaustive `public-interface-freeze.md` blueprint into compiling declarations and verify its nil-success representations, attributes, conversion names, and callback declarations; no new public design choice may be introduced in this stage;
- pin Reference Odin, Ryu provenance, and a source checkout/build of `toml-test` at its full commit (rather than mutable or platform-specific binary acquisition);
- add strict normal and `-o:speed` compile/test jobs;
- establish public/private declaration linting and no-runtime-external-dependency check.

Exit: the package skeleton, exact public declarations, and test executables compile on the Reference Odin revision; declaration tests cover option defaults and nil error success; CI records `odin version`/`odin report`; no Go/C oracle code is linked into published packages. Any Reference-Odin syntax incompatibility is reported against the frozen blueprint; a semantic/interface change returns to design review.

### Stage 1 — Temporal and RTTI feasibility probes

Deliver:

- complete `temporal` values, validation, compare, and explicit conversions;
- test-only compile probes for field/tag enumeration, destination-backed `any`, named-type handling, optional unions, zero-size pointer allocation, and map/dynamic-array allocator behavior; document the package-wide normal-RTTI requirement.

Exit: temporal matrix is green; every generic binding mechanism required by issue 11 is demonstrated against the exact compiler. Any missing compiler capability returns to design review.

### Stage 2 — Semantic owners and allocator lifecycle

Deliver:

- `Value`, `Document`, containers, lifecycle, direct table operations, common tree walker;
- tracking/fail-at-N/external-lifetime allocator support;
- cycle/alias/allocator-consistency validation infrastructure.

Exit: clone/destroy/get/set/remove/order/borrow tests and ordinal allocation sweeps pass; explicit allocator use works with a rejecting ambient allocator. `set` tests cover local subtree depths 256/257, unchanged state on local-depth failure, and a nested successful set whose enclosing document is later rejected by a stricter/root-relative encode limit. Compile-tested examples initialize and clean standalone transparent tables/arrays with the intended allocator.

### Stage 3 — Canonical scalar primitives

Deliver:

- UTF-8 scalar validation and canonical key/string escaping;
- checked integer formatting;
- a correctly rounded decimal-to-binary64 conversion feasibility implementation for parser use, including overflow, subnormal, halfway, and signed-underflow cases;
- an independent test-only exact-rational decimal oracle built with Reference Odin `core:math/big` integers/rationals: parse the decimal exactly, bracket adjacent binary64 values, and select by exact distance with ties-to-even; it is algorithmically separate from the runtime converter and needs no external acquisition or license;
- canonical binary64 formatting with pinned Ryu oracle and no runtime C dependency;
- TOML temporal parse/format primitives independent of the full parser.

Exit: both float directions are proven against independent vectors/oracles before parser or encoder integration; exact scalar goldens, exhaustive named boundary vectors, deterministic raw-bit float sampling, and temporal normalization/canonicalization tests pass. Failure to meet the exact conversion contract is a design escalation.

### Stage 4 — Strict parser and diagnostics

Deliver:

- UTF-8 preflight, pull lexer, recursive parser, definition sidecar, source ranges, bounded parse paths;
- public parse entry points with transactional cleanup.

Exit: focused parser/definition/diagnostic/depth suites and parse fail-at-N sweeps pass; accepted documents have semantic order/invariants; no input borrow escapes.

### Stage 5 — Semantic canonical encoder

Deliver:

- common semantic preflight/plan/emitter;
- `unparse` and writer form;
- cycle/alias/data/depth/size diagnostics and exact writer handling.

Exit: semantic exact-byte goldens, parse/unparse properties, allocated/writer identity, writer fault matrix, and encoder fail-at-N sweeps pass.

### Stage 6 — Typed marshal and codec marshaling

Deliver:

- registry lifecycle and exact directional lookup;
- reflection/tag/map/sequence/wrapper planning;
- typed marshal preflight, exact-once cached semantic codec values, and common canonical emission.

Exit: marshal kind/tag/order/omit/root/codec matrices, deterministic map tests, callback ownership/order tests, cycle tests, writer faults, and allocator sweeps pass.

### Stage 7 — Typed unmarshal and codec unmarshaling

Deliver:

- temporary parse-with-ranges path;
- full generic preflight and clean-slot validation;
- ownership-safe commit units for all supported kinds;
- unknown-field mode and transactional custom destination slots.

Exit: typed compatibility/range/tag/field/container/partial-state matrices pass; preflight errors leave destination unchanged; every installation allocation ordinal leaves a recursively cleanable wholly-zero-start destination and no package leak. A separate provenance test seeds missing/ignored fields from a different allocator, proves they remain untouched, cleans only package-installed matched commit units, and proves neither allocator sees a foreign free.

### Stage 8 — Adapters, official conformance, and properties

Deliver:

- strict test-only tagged-JSON decoder and encoder adapters;
- pinned official command/report integration;
- generated semantic/application properties and deterministic replay seeds.

Exit: `toml-test` reports zero valid, invalid, and encoder failures and zero skips under literal TOML 1.1.0; adapter negative tests and all required properties pass.

### Stage 9 — Fuzzing, sanitizers, and platform completion

Deliver:

- six coverage-guided targets and ordinary deterministic mutation budgets;
- ASan/TSan jobs and complete five-platform normal/speed matrix;
- minimized regression corpus and release evidence assembly.

Exit: mandatory platform/mode matrix is green; 300-second aggregate PR fuzz smoke is green; no unresolved sanitizer, bad-memory, race, fuzz, skip, or expected-failure artifact remains. No additional compile-only architecture is claimed or gated initially; `linux_i386`, `windows_i386`, `linux_riscv64`, and `wasi_wasm32` require a later explicit support/compile-check decision.

### Stage 10 — Documentation, benchmark baseline, and release candidate

Deliver:

- public interface/ownership/error examples, typed cleanup examples, registry concurrency rules, support matrix, and non-goals;
- benchmark baselines for parse, semantic encode, typed marshal/unmarshal, large ordered tables, deeply nested inputs, map sorting, and codec-heavy paths;
- encoded-size baselines for the inline-only profile;
- complete issue-13 acceptance bundle.

Exit: documentation matches executable tests; benchmark results are archived as non-gating baselines with reproducible commands; the full release-candidate bundle is reviewed and green. A later regression policy may add thresholds only from measured evidence and a separate approved decision.

## 17. Approval checklist

The design is implementation-ready because it freezes:

- the two-module dependency direction and exact initial file responsibilities;
- public procedure families and options;
- semantic and temporal representations;
- allocation ownership, borrowing, destruction, and partial-failure behavior;
- strict parser state, limits, diagnostics, and precedence;
- deterministic bytes and traversal order;
- typed mappings, tags, wrappers, unknown fields, and cleanup;
- per-call exact-type codec ownership and callback rules;
- complete conformance/acceptance gates, non-goals, risks, and stage exits.

Implementation may refine private algorithms and move private declarations between files. It must escalate any change to a public interface, documented ownership transfer, strict acceptance rule, canonical byte, typed mapping, codec behavior, diagnostic contract, or acceptance gate rather than treating it as an implementation detail.

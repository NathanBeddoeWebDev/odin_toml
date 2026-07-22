# Implement a standalone Odin TOML 1.1 package

Status: ready-for-agent

## Problem Statement

Odin developers do not currently have a standalone TOML library in this repository that can strictly consume complete TOML 1.1 documents, preserve their semantic meaning in an allocator-owned document tree, deterministically produce TOML, or bind TOML values to application-defined Odin types.

A useful implementation must do more than parse common examples. It must enforce TOML’s stateful table-definition rules, preserve all four temporal kinds without inventing timezone information, produce stable bytes across runs and platforms, integrate safely with Odin’s explicit allocator model, expose actionable allocation-free diagnostics, and remain correct under partial failures. It must also support application types through reflection and caller-supplied codecs without introducing global mutable state.

Without these guarantees, applications risk accepting invalid configuration, emitting nondeterministic output, losing temporal meaning, leaking or freeing memory through the wrong allocator, mutating destinations before validation has completed, or depending on behavior that changes across machines and compiler revisions.

## Solution

Build two public Odin packages:

- `toml`, a repository-root package for strict complete-document TOML 1.1 parsing, semantic document ownership and mutation, deterministic serialization, reflection-based typed marshal/unmarshal, direct writer output, structured diagnostics, and caller-owned custom codec registries.
- `temporal`, an allocation-free sibling package for the civil and fixed-offset values required by TOML, including validation, comparison, and explicit conversions to and from Odin core time representations.

The semantic document tree will own decoded strings, insertion-ordered tables, heterogeneous arrays, and distinct temporal values through one caller-selected allocator. Parsing and owner-producing operations will be transactional. Typed unmarshal will validate the complete binding before installation and will use documented ownership-safe commit units when allocation failure occurs during installation.

Serialization will use one compact canonical profile shared by semantic unparse and typed marshal. Output will be deterministic by semantic table insertion order, reflected struct declaration order, array order, and lexically sorted converted map keys. Writer forms will perform complete package-controlled preflight before emitting any byte.

The package will expose only the high-level public workflows needed by applications. Lexer state, parser state, reflection plans, encoder plans, float algorithms, and diagnostic construction remain private. The public package interfaces are also the primary test seam, supplemented only by test-only compiler feasibility probes, independent numerical oracles, conformance adapters, allocators, writers, and fuzz harnesses.

## User Stories

1. As an Odin application developer, I want to parse a complete TOML 1.1 byte document, so that I can consume standards-compliant configuration.
2. As an Odin application developer, I want to parse a complete TOML 1.1 string document, so that I can use the most convenient source representation without semantic differences.
3. As an Odin application developer, I want empty, whitespace-only, and comment-only documents to produce a valid empty document, so that optional configuration files need no special case.
4. As an Odin application developer, I want malformed UTF-8 rejected before parsing, so that invalid text cannot enter the semantic document tree.
5. As an Odin application developer, I want the parser to reject trailing or partially consumed input, so that configuration mistakes cannot be hidden behind a valid prefix.
6. As an Odin application developer, I want strict TOML whitespace, newline, comment, key, string, number, array, and inline-table rules, so that accepted files have portable TOML 1.1 meaning.
7. As an Odin application developer, I want duplicate keys and illegal table redefinitions rejected after decoded-path resolution, so that syntactically different spellings cannot overwrite values silently.
8. As an Odin application developer, I want dotted keys, implicit tables, standard table headers, inline tables, and arrays of tables to obey TOML’s stateful definition rules, so that complex documents are interpreted correctly.
9. As an Odin application developer, I want nested arrays of tables to attach children to the latest applicable parent element, so that parsed structure matches TOML semantics.
10. As an Odin application developer, I want integers checked against the semantic `i64` range, so that overflow is diagnosed rather than wrapped.
11. As an Odin application developer, I want finite decimal floats converted to correctly rounded `f64` values, so that numeric meaning is not platform- or algorithm-dependent.
12. As an Odin application developer, I want signed zero, subnormal values, underflow sign, infinities, and TOML NaN forms handled deliberately, so that floating-point edge cases have stable semantics.
13. As an Odin application developer, I want offset date-time, local date-time, local date, and local time stored as distinct value kinds, so that missing offset or component information is never invented.
14. As an Odin application developer, I want unknown `-00:00` offsets preserved separately from known UTC, so that RFC 3339 uncertainty is not lost.
15. As an Odin application developer, I want temporal fractions longer than nanoseconds truncated rather than rounded, so that decoding follows the package’s documented precision policy.
16. As an Odin application developer, I want leap-second values represented structurally without unsupported historical claims, so that valid TOML grammar is preserved without bundling an IERS database.
17. As an Odin application developer, I want parsed tables to preserve semantic insertion order, so that deterministic output reflects the document’s first semantic definition order.
18. As an Odin application developer, I want arrays to preserve order and permit heterogeneous TOML values, so that the full TOML data model is available.
19. As an Odin application developer, I want keys and semantic paths to use exact decoded strings, so that quoted dots, case differences, and normalization differences remain meaningful data.
20. As an Odin application developer, I want every successful parse result to own all reachable allocations through my selected allocator, so that lifetime and cleanup are predictable.
21. As an Odin application developer, I want parsing failures to return a zero result and clean every partial allocation, so that error handling does not leak memory.
22. As an Odin application developer, I want to destroy a document idempotently through its recorded allocator, so that cleanup is simple and repeated cleanup is safe.
23. As an Odin application developer, I want to deep-clone a document or standalone value into a selected allocator, so that I can create independent ownership lifetimes.
24. As an Odin application developer, I want failed clones to leave the source unchanged and clean all partial ownership, so that cloning is transactional.
25. As an Odin application developer, I want to look up table values without transferring ownership, so that read access does not require allocation.
26. As an Odin application developer, I want lookup borrow invalidation rules documented, so that I do not retain pointers across structural mutation or destruction.
27. As an Odin application developer, I want table insertion and replacement to deep-clone caller values, so that table ownership cannot alias application ownership accidentally.
28. As an Odin application developer, I want replacement to preserve insertion position and new insertion to append, so that semantic order remains stable.
29. As an Odin application developer, I want removal to destroy the removed owner and stably compact the table, so that no detached ownership is leaked.
30. As an Odin application developer, I want malformed caller-constructed semantic trees rejected before clone or encoding, so that duplicate keys, invalid text, cycles, aliases, and allocator mismatches do not cause unsafe behavior.
31. As an Odin application developer, I want direct table mutation to enforce the documented local hard depth limit, so that it does not pretend to know an unavailable document-relative path.
32. As an Odin application developer, I want root-relative operations to enforce their selected depth limit independently, so that a locally valid nested mutation cannot bypass operation policy.
33. As an Odin application developer, I want explicit support for externally reclaimed allocators, so that arena-style ownership can be logically destroyed without invalid individual frees.
34. As an Odin application developer, I want unsupported allocator operations reported exactly, so that allocator capability failures are not collapsed into generic errors.
35. As an Odin application developer, I want to serialize a semantic document to an owned string, so that I can store or transmit canonical TOML.
36. As an Odin application developer, I want to serialize directly to an `io.Writer`, so that I can avoid a final output allocation where a writer is appropriate.
37. As an Odin application developer, I want empty documents to emit zero bytes and make zero writer calls, so that empty output has no hidden allocation or I/O.
38. As an Odin application developer, I want semantic unparse and typed marshal to use the same canonical spelling engine, so that equivalent values cannot produce conflicting TOML styles.
39. As an Odin application developer, I want canonical output to use quoted keys, root assignments, inline nested tables, ordinary arrays, and LF newlines, so that output bytes are simple and portable.
40. As an Odin application developer, I want canonical escaping for strings and keys, so that valid Unicode remains readable and controls are represented unambiguously.
41. As an Odin application developer, I want canonical integer, float, boolean, and temporal spellings, so that repeated encoding is byte-identical.
42. As an Odin application developer, I want every finite nonzero `f64` encoded with the package’s shortest correctly rounded decimal rule, so that output is compact and reparses exactly.
43. As an Odin application developer, I want all NaN payloads normalized to canonical `nan`, so that host-specific payload metadata cannot affect output.
44. As an Odin application developer, I want writer preflight to validate the complete source before the first write, so that package-detectable failures never leave output prefixes.
45. As an Odin application developer, I want short writes, invalid counts, and explicit writer errors handled exactly once without retries, so that writer behavior follows Odin’s I/O contract.
46. As an Odin application developer, I want accepted writer bytes to be an exact prefix of canonical output on I/O failure, so that non-transactional output remains understandable.
47. As an Odin application developer, I want allocated and writer forms to produce identical bytes on success, so that output destination does not change serialization.
48. As an Odin application developer, I want to marshal eligible application structs and maps into TOML, so that I do not need to construct semantic trees manually.
49. As an Odin application developer, I want typed roots to represent TOML root tables, so that unsupported scalar or sequence roots fail clearly.
50. As an Odin application developer, I want exact same-category scalar binding with checked range behavior, so that implicit coercions cannot hide data errors.
51. As an Odin application developer, I want exact matching temporal types in typed binding, so that strings or generic time types are not inferred ambiguously.
52. As an Odin application developer, I want structs projected by exact field names and explicit `toml` tags, so that application schemas are predictable.
53. As an Odin application developer, I want anonymous `using` structs flattened in declaration order, so that composed schemas encode naturally and deterministically.
54. As an Odin application developer, I want malformed tags and effective-name collisions rejected before data traversal or destination mutation, so that ambiguous schemas cannot partially execute.
55. As an Odin application developer, I want `toml:"-"` to ignore a complete field subtree in both directions, so that unsupported or private application state can be excluded.
56. As an Odin application developer, I want `omitempty` to follow a precise finite set of zero and empty states, so that omission is stable and does not invoke arbitrary recursive emptiness rules.
57. As an Odin application developer, I want converted map keys sorted by unsigned UTF-8 bytes, so that host map iteration cannot affect output.
58. As an Odin application developer, I want converted map-key collisions rejected, so that distinct application keys cannot overwrite one semantic key.
59. As an Odin application developer, I want fixed arrays, slices, dynamic arrays, maps, pointers, and optional unions supported under explicit ownership rules, so that common Odin models can bind safely.
60. As an Odin application developer, I want unsupported kinds and nil states rejected explicitly, so that typed behavior is closed rather than accidental.
61. As an Odin application developer, I want repeated acyclic references encoded by value and active recursion cycles rejected, so that shared application graphs cannot cause unbounded recursion.
62. As an Odin application developer, I want to unmarshal complete TOML documents into eligible application structs and maps, so that configuration can populate typed state.
63. As an Odin application developer, I want typed unmarshal to strictly parse into a temporary semantic tree before binding, so that parse errors are independent of destination state.
64. As an Odin application developer, I want complete binding preflight before destination mutation, so that schema, range, unknown-field, depth, size, and zero-ownership errors leave my destination unchanged.
65. As an Odin application developer, I want missing fields left unchanged, so that partial configuration can preserve application defaults.
66. As an Odin application developer, I want ignored fields left uninspected and unchanged, so that excluded ownership cannot be disturbed.
67. As an Odin application developer, I want unknown struct fields ignored by default, so that compatible configuration evolution is possible.
68. As an Odin application developer, I want an option to reject unknown fields recursively, so that strict application schemas can catch misspellings.
69. As an Odin application developer, I want matched owning destination slots required to be clean, so that unmarshal never silently overwrites storage it cannot safely release.
70. As an Odin application developer, I want installation allocation failure to leave only documented ownership-safe committed units, so that I can recursively clean a wholly zero-start destination.
71. As an Odin application developer, I want source strings cloned rather than aliased into the destination, so that the input may be released immediately after unmarshal.
72. As an Odin application developer, I want parse and unmarshal diagnostics to remain valid after input release, so that errors can be returned or logged later.
73. As an Odin application developer, I want diagnostics with exact error categories, source ranges, related definitions, semantic paths, types, and wrapped external errors, so that failures are actionable without parsing text messages.
74. As an Odin application developer, I want bounded allocation-free diagnostic snapshots, so that error reporting cannot itself fail due to allocation.
75. As an Odin application developer, I want source byte offsets, line numbers, and Unicode-scalar columns defined precisely, so that editors and tools can locate errors consistently.
76. As an Odin application developer, I want a caller-owned codec registry keyed by exact `typeid`, so that application-specific conversions are opt-in and local to one call.
77. As an Odin application developer, I want marshal and unmarshal codecs registered independently, so that one-way and paired conversions are both possible.
78. As an Odin application developer, I want duplicate directional registration rejected, so that callback selection is unambiguous.
79. As an Odin application developer, I want codec lookup to occur before generic named-type and temporal handling, so that exact application types can override generic binding deliberately.
80. As an Odin application developer, I want codecs excluded from map-key conversion, so that deterministic key semantics remain closed and auditable.
81. As an Odin application developer, I want custom marshalers to return semantic values rather than raw TOML, so that canonical validation and formatting cannot be bypassed.
82. As an Odin application developer, I want custom marshalers invoked exactly once per encountered node during preflight, so that callbacks with observable work behave deterministically.
83. As an Odin application developer, I want successful codec-produced values cleaned by the package on every later return path, so that temporary ownership does not leak.
84. As an Odin application developer, I want a failing custom unmarshaler to restore its entire supplied destination slot to zero, so that codec-local failure is transactional.
85. As an Odin application developer, I want callback allocator errors and nonzero application failure codes preserved distinctly, so that I can diagnose infrastructure and domain failures separately.
86. As an Odin application developer, I want a frozen registry to support concurrent read-only calls, so that shared immutable codec policy does not require package-global state.
87. As an Odin library maintainer, I want all non-interface declarations private, so that implementation algorithms can evolve without expanding compatibility obligations.
88. As an Odin library maintainer, I want the package-wide normal-RTTI requirement stated explicitly, so that semantic-only consumers do not expect unsupported `ODIN_NO_RTTI` builds.
89. As an Odin library maintainer, I want the initial compiler revision pinned, so that language and core-library behavior is reproducible during implementation.
90. As an Odin library maintainer, I want the official TOML 1.1 conformance corpus pinned and run with explicit version selection, so that acceptance cannot drift silently.
91. As an Odin library maintainer, I want deterministic independent float conversion and formatting oracles, so that self-round-tripping cannot mask a shared numerical defect.
92. As an Odin library maintainer, I want exhaustive allocator and writer fault injection, so that every failure ordinal proves cleanup and exact propagation.
93. As an Odin library maintainer, I want deterministic property tests and replayable fuzz failures, so that composition defects become stable regressions.
94. As an Odin library maintainer, I want sanitizer, bad-memory, race, mode, and target gates, so that ownership and concurrency guarantees hold beyond happy-path local tests.
95. As an Odin library maintainer, I want a release evidence bundle with no skipped or expected failures, so that conformance claims are reviewable.
96. As an Odin library maintainer, I want benchmark and encoded-size baselines recorded only after correctness, so that optimization does not weaken frozen behavior.
97. As a future package consumer, I want semantic versioning to protect the public interface, ownership contracts, strict acceptance behavior, and deterministic bytes from version 1.0 onward, so that upgrades are predictable.

## Implementation Decisions

- The implementation consists of the public `toml` package and a reusable public `temporal` package. `toml` depends on `temporal`; `temporal` never depends on `toml`.
- The initial implementation targets exactly Reference Odin `dev-2026-07:2c25fb924`. The complete `toml` package requires normal RTTI because its frozen typed-binding declarations use `any`; `ODIN_NO_RTTI` builds are unsupported.
- The public interface is limited to complete-document parse, semantic unparse, typed marshal/unmarshal, writer output, semantic ownership lifecycle, direct table mutation, temporal operations, and codec registry lifecycle/registration.
- The exact `toml` procedure surface is the `parse` overload group (`parse_bytes` and `parse_string`); `unparse` and `unparse_to_writer`; `marshal` and `marshal_to_writer`; `unmarshal` and `unmarshal_string`; `clone_document`, `destroy_document`, `clone_value`, and `destroy_value`; `get`, `set`, and `remove`; and `init_codec_registry`, `destroy_codec_registry`, `register_marshaler`, and `register_unmarshaler`. No encode/decode aliases or additional convenience families are introduced.
- `Parse_Options` contains only `max_depth`. `Marshal_Options` contains `max_depth` and a borrowed codec-registry pointer. `Unmarshal_Options` contains `max_depth`, `reject_unknown_fields`, and a borrowed codec-registry pointer. Allocating and non-writer forms take options by value with a zero-value default; writer forms take a required stable options pointer. Allocator defaults are the context allocator and source-location defaults are caller location.
- Every public procedure returning an owned result, an error, or a meaningful lookup/removal boolean requires its result to be consumed. Result-less cleanup procedures do not use that requirement.
- The exact `temporal` procedure surface consists of the `validate` overload group (`validate_local_date`, `validate_local_time`, `validate_local_date_time`, `validate_utc_offset`, and `validate_offset_date_time`); the civil `compare` overload group (`compare_local_date`, `compare_local_time`, and `compare_local_date_time`); `compare_instant`; `local_date_to_datetime` and `local_date_from_datetime`; `local_time_to_datetime` and `local_time_from_datetime`; `local_date_time_to_datetime` and `local_date_time_from_datetime`; and `offset_date_time_to_time`, `offset_date_time_from_time_utc`, and `offset_date_time_from_time`.
- The codec registry publicly exposes its directional exact-type maps, retained allocator, and initialized state because Odin has no private fields, but callers treat map contents as implementation-owned. A marshaler registration stores a procedure and raw user-data pointer; its callback receives the source as `any`, user data, selected allocator, and caller location and returns a semantic `Value` plus callback error. An unmarshaler registration stores the analogous procedure and user data; its callback additionally receives a borrowed semantic-value pointer and exact destination slot and returns only callback error. Callback error is either a nonzero application code payload or an exact allocator error.
- The public error surface consists of `Parse_Error`, `Clone_Error`, `Mutation_Error`, `Unparse_Error`, `Marshal_Error`, `Unmarshal_Error`, `Codec_Registry_Error`, and the allocation-free `temporal.Error` enum. The TOML error unions use nil as success; `temporal.Error` uses `.None` as success.
- Parse errors distinguish configuration, input encoding, lexical, grammar, scalar-value, table-definition, depth/size-limit, and exact allocator failures. Clone and mutation errors distinguish invalid owners or values, invalid containers/text/temporals, duplicate keys, cycles, aliases, allocator mismatch, depth/size limits, and exact allocator failures where allocation is possible. Unparse adds exact writer errors for writer forms. Marshal adds root shape, unsupported type/nil, numeric range, tag/field/map collisions, active recursion, codec semantic ownership, codec failure code, and exact writer or allocator errors. Unmarshal wraps the complete parse error and distinguishes root/destination type, kind mismatch, numeric range, fixed-array length, tags/fields, unknown fields, nonzero destination ownership, size/depth, codec failure code, and exact allocator errors. Registry errors distinguish invalid allocator, registry, type ID, callback, duplicate directional codec, and exact allocator failure.
- Diagnostic payloads retain the frozen source ranges, related definitions, bounded semantic paths, temporal sub-errors, source/destination/related type IDs, source value kind, expected/actual counts, registered codec type, callback code, and exact wrapped external values applicable to each error. Unused fields remain zero, and precedence follows the approved declaration freeze.
- Lexer, parser definition state, source tracking, semantic traversal, reflection plans, encoder plans, float conversion/formatting, and diagnostic construction are private implementation details.
- The semantic value set is closed and non-null: string, `i64`, `f64`, boolean, four exact temporal kinds, heterogeneous array, and insertion-ordered table.
- A document contains an initialized root semantic table and records the allocator that owns its complete reachable tree. Zero documents and zero containers are not valid initialized owners.
- Semantic tables use one authoritative insertion-ordered entry sequence with unique exact decoded UTF-8 keys. Arrays preserve order and may be heterogeneous. Arrays of tables have no retained syntax provenance after parsing.
- Package-produced trees are acyclic, exclusively owned, initialized, and uniform-allocation. Caller-constructed trees are validated at lifecycle and encoding boundaries rather than trusted.
- Semantic paths contain exact decoded key and array-index segments. Dots within decoded keys remain data.
- Parsing consumes a complete byte or string document. It rejects a nil allocator, validates options, performs whole-input RFC 3629 UTF-8 preflight, initializes semantic and definition state, parses lazily, requires EOF, and transfers ownership only on success.
- The parser is strict TOML 1.1 only. It accepts TOML TAB/SPACE and LF/CRLF rules and rejects BOMs, bare CR, non-TOML whitespace, invalid controls, malformed strings and escapes, invalid scalar prefixes, malformed UTF-8, and trailing input.
- Parser definition state distinguishes root, implicit, standard-header, dotted-defined, inline-sealed, scalar/static-array, array-of-tables containers, and individual array-of-table elements. Stable private IDs are used so no pointer into resizable semantic storage survives a fallible append.
- Duplicate and transition checks operate on decoded semantic paths and implement TOML prose semantics, including late implicit-parent definition, dotted-table restrictions, inline-table isolation, table/array kind conflicts, and latest-parent array-of-table binding.
- Integer parsing uses checked accumulation into `i64`. Finite decimal floats convert to correctly rounded `f64`, preserve signed zero and subnormal behavior, reject finite overflow, accept explicit infinities, and normalize TOML NaN spellings.
- Scalar error classification follows the frozen deterministic candidate precedence so malformed booleans, temporals, radix integers, decimal integers, floats, and unknown values report stable categories.
- TOML parsing and formatting own temporal text behavior. Fractions are represented to nanoseconds and extra digits are truncated, never rounded.
- `temporal` exposes transparent allocation-free values for local date, local time, local date-time, UTC offset with known/unknown state, and offset date-time.
- Temporal validation uses proleptic Gregorian dates, years 0000 through 9999, times through structural second 60, nanoseconds below one billion, known offset minutes from -1439 through 1439, and zero minutes for unknown offsets.
- `temporal.Error` has exactly these outcomes: `.None`, `.Invalid_Year`, `.Invalid_Month`, `.Invalid_Day`, `.Invalid_Hour`, `.Invalid_Minute`, `.Invalid_Second`, `.Invalid_Nanosecond`, `.Invalid_Offset_Kind`, `.Invalid_Offset_Minutes`, `.Invalid_Unknown_Offset`, `.Unsupported_Leap_Second`, `.Out_Of_Range`, `.Timezone_Not_Local`, and `.Leap_Second_Not_Comparable`. Validation checks date before time before offset, components in field order, and the left operand completely before the right operand.
- Temporal comparison validates operands first. Civil comparison returns ordering plus error. Instant comparison applies known displacement; unknown offset uses zero numeric displacement while retaining its state. Differently offset leap seconds that cannot be compared return the dedicated error.
- Temporal conversion to and from Odin core time representations is explicit. It rejects information loss, unsupported leap seconds, range overflow, and non-local values and never consults machine timezone state.
- `max_depth` value zero selects 128. Explicit values range from 1 through the hard maximum 256. Depth is semantic path length from root table depth zero, and a child beyond the limit is rejected before allocation or installation.
- Direct table `set` validates depth locally from the target table because its interface does not carry a document path. Root-relative clone, parse, unparse, marshal, and unmarshal enforce their own selected limits.
- Parsing empty input is the canonical way to obtain an initialized empty document. No public builder or constructor is added.
- Every allocating owner-producing operation accepts an explicit allocator defaulting to the context allocator and forwards caller location. After selection, no path falls back to ambient allocation.
- Parse, clone, semantic mutation, allocated encoding, registry creation, and package-owned codec temporaries have explicit ownership-transfer and failure-cleanup contracts.
- `destroy_document` uses the allocator stored in the document, recursively ends descendant ownership, invalidates borrows, and zeros the document. Repeated destruction is a no-op.
- `clone_document` and `clone_value` produce independent deep ownership in the selected allocator and return zero results after any failure.
- `get` returns a borrowed value pointer and presence flag. Structural mutation or destruction of the containing table invalidates the borrow.
- `set` deep-clones the key and value using the target table’s retained allocator. Failure leaves the table physically and semantically unchanged. Replacement preserves position; insertion appends.
- `remove` performs no allocation, destroys the removed key/value through the table owner, stably compacts entries, and reports absence as false.
- Destruction and destructive mutation require either a zero owner or a valid acyclic, exclusive, allocator-consistent owner. They are not salvage operations for malformed aliases, cycles, or mixed allocators.
- Allocators supporting arbitrary individual free receive ordinary destruction. External-lifetime allocators are logically zeroed and reclaimed through their external lifetime, following the frozen allocator capability and unsupported-mode rules. No package destructor invokes global `Free_All`.
- No generic typed destructor is provided. Typed-unmarshal documentation defines recursive application cleanup for strings, structs, arrays, slices, dynamic arrays, maps, pointers, and optional unions.
- A wholly zero projected typed destination is the generally safe pattern for mechanical cleanup after partial installation. Missing and ignored pre-existing ownership remains application-managed and is never inferred by the package.
- All errors are allocation-free values. TOML error unions use nil success states; `temporal.Error` is an enum whose `.None` value indicates success. External allocator and writer errors are preserved exactly where specified.
- Parse diagnostics use zero-based byte offsets, one-based line and Unicode-scalar columns, and half-open original-source ranges. EOF expectations use empty ranges.
- Parse and unmarshal errors never borrow source input. Long diagnostic paths and keys use bounded first/last UTF-8-safe snapshots with exact omission metadata.
- Encode diagnostics borrow stable key/name strings from their documented source lifetime and copy array indexes into a bounded path snapshot.
- Every error family and detail category from the approved declaration freeze is part of the compatibility contract. Implementation does not collapse, rename, or silently reprioritize frozen alternatives.
- Semantic unparse and typed marshal share one canonical semantic validation, planning, and emission engine. They cannot develop separate spelling rules.
- Canonical output writes every root entry as a quoted-key assignment followed by LF. Nested tables are inline, arrays use ordinary array syntax, and non-empty containers use fixed single-space comma and brace rules.
- Canonical output emits no comments, headers, dotted keys, indentation, blank lines, trailing commas, or platform-native newlines.
- Traversal order is semantic table insertion order, struct declaration and flatten-expansion order, array order, and unsigned UTF-8 lexical order of converted map keys. Equal converted map keys are errors.
- Keys and strings use one-line basic strings with fixed escape choices. Invalid Unicode scalar text is rejected rather than repaired.
- Canonical scalar spelling includes minimal base-ten integers; `0.0` and `-0.0`; explicit infinities; normalized `nan`; shortest correctly rounded finite binary64 decimals under the frozen fixed/scientific selection rule; and fixed-width canonical temporal values.
- Both allocated and writer encoding forms perform complete package-controlled preflight. Preflight checks configuration, source shape, UTF-8, temporals, duplicate keys, initialized containers, depth, checked sizes, cycles, aliases, and allocator consistency.
- Typed marshal preflight additionally resolves fields, tags, map keys, wrappers, and codecs. Custom marshaler results are cached through emission.
- Writer emission starts only after successful preflight. Each writer result is consumed once and never retried. Explicit errors win even when bytes were accepted; invalid counts and nil-error short writes receive dedicated I/O errors.
- Successful non-empty allocated output has allocation size exactly equal to returned length. Empty successful output has nil backing and owns no allocation.
- Typed roots are table-shaped after exact codec lookup and non-nil wrapper resolution. Generic roots are eligible structs or maps; generic scalar, temporal, and sequence roots are rejected.
- Generic typed mapping is closed and same-category. Strings, booleans, signed/unsigned integers, floats, exact temporals, arrays/sequences, structs, and eligible maps follow the approved checked conversion rules. No implicit integer/float crossover, enum conversion, stringification, temporal inference, or union selection by source kind is allowed.
- Struct projection uses exact case-sensitive field names unless a valid `toml` tag renames, ignores, or marks a field `omitempty` for marshal.
- Anonymous `using` structs flatten recursively at declaration position under the frozen wrapper-tag constraints. Named `using` fields remain ordinary named fields.
- The complete tag list is validated. Unknown, duplicate, empty, trailing, whitespace-padded, malformed, and multiple TOML tag entries are errors. Effective names after flattening and renaming must be unique.
- `omitempty` is evaluated before codec lookup and traversal and applies only to the approved false, numeric zero, zero-length, nil pointer, nil optional, and nil `any` states. Structs and temporals are never empty, and non-nil wrappers are not recursively omitted.
- Generic map keys are strings or named/distinct strings only. Codecs never apply to map keys. Converted output keys are sorted, and conversion collisions fail.
- Fixed and enumerated arrays require exact length. Slice and dynamic-array storage is installed before elements. Map unmarshal requires a nil map and commits complete key/value pairs in semantic insertion order.
- Ordinary pointers require non-nil values for marshal unless omitted and nil clean slots for unmarshal. Zero-size pointees receive an aligned sentinel allocation.
- Generic optional unions have exactly one non-nil alternative and a nil state. Present TOML activates the alternative; TOML never synthesizes nil.
- Marshal recursively unwraps non-nil `any`; generic unmarshal into `any` is unsupported.
- Repeated acyclic references encode by value. Active recursion cycles fail with a typed diagnostic.
- Typed unmarshal has three phases: strict parse into a temporary ranged semantic tree, complete binding and ownership preflight without destination mutation, and ordered installation.
- Configuration, parse, schema, type, range, unknown-field, destination-state, depth, size, and preflight-allocation failures leave the complete destination unchanged.
- Installation-allocation failure may leave earlier ownership-safe commit units installed. The package cleans uninstalled state; the application owns committed state immediately and cleans it with the selected allocator.
- Matched owning destination slots must be clean/zero. Missing and ignored fields are not inspected or changed.
- Unknown struct fields are ignored by default and rejected recursively in semantic insertion order when requested. Maps have no unknown-field mode.
- The codec registry is caller-owned, per-call, exact-`typeid`, and directional. It owns lookup storage through its recorded allocator but never owns callbacks or user data.
- Duplicate registration in one direction fails. Marshal and unmarshal callbacks for the same exact type may coexist.
- Registry lookup occurs before named-type unwrapping and generic or temporal handling at each typed node. Wrapper codecs may target exact pointer or optional types. Map keys never consult codecs.
- Frozen registry reads may be concurrent. Registration or destruction during an active TOML call is a caller contract violation.
- A custom marshaler runs exactly once per encountered node during preflight and returns a complete semantic value allocated through the supplied allocator. It cannot return raw TOML.
- The package owns every successful custom-marshaler value through validation and emission and destroys it on every later return path.
- A custom unmarshaler receives a borrowed semantic value and an exact clean destination slot. Callback failure must restore that entire slot to exact zero; success transfers installed ownership to the application.
- Callbacks cannot retain borrows, mutate sources, re-enter active typed TOML operations, or access parser/writer implementation state.
- Before 1.0, documented breaking changes are allowed. From 1.0, semantic versioning protects public declarations, ownership contracts, strict TOML 1.1 behavior, and deterministic output bytes.
- Implementation is staged by dependency and risk: reproducible scaffold and interface transcription; temporal and RTTI probes; semantic ownership; numeric and temporal scalar primitives; strict parser; semantic encoder; typed marshal and codec marshal; typed unmarshal and codec unmarshal; official adapters and properties; fuzzing/platform completion; documentation, baselines, and release evidence.
- Failure of a Reference Odin RTTI, allocator, or exact float feasibility gate returns the design for review. It does not permit silently weakening an approved contract.

## Testing Decisions

- Tests assert external behavior and ownership contracts rather than private implementation details. Lexer tokens, parser objects, definition sidecars, reflection plans, encoder plans, and formatting internals are not public test seams.
- The primary and highest test seam is the public `toml` and `temporal` interface. Complete inputs enter through parse/unmarshal, semantic or typed values enter through unparse/marshal, and results are observed as semantic trees, application state, canonical bytes, structured errors, allocator state, and writer traces.
- Test-only conformance adapters, independent float oracles, allocator wrappers, scripted writers, compiler probes, and fuzz harnesses support this public seam without becoming published library APIs.
- Prior art is the installed Reference Odin encoding packages for allocator-explicit procedures, fail-at-N allocation testing, writer behavior, bad-memory checks, deterministic random seeds, and public API conventions.
- Strict TOML language prior art is the pinned official `toml-lang/toml-test` v2.2.0 corpus at commit `ce08da1ddb075d1c7596d663c7fcba9a2ae02c5c`, always invoked with literal TOML version 1.1.0.
- The official decoder and encoder adapters use only public package operations. Acceptance requires zero valid-decoder failures, zero invalid-decoder failures, zero encoder failures, and zero skips, with a preserved machine-readable report and provenance.
- Focused parser tests cover complete-input behavior; UTF-8; whitespace/newlines/comments; every key and string form; escapes and controls; integer, float, boolean, and temporal boundaries; arrays; inline tables; dotted keys; headers; duplicate definitions; table transitions; array-of-table latest-element behavior; insertion order; and depth boundaries.
- Every parser rejection family includes a nearest valid neighbor. Every accepted TOML 1.1 form includes adjacent malformed, prefix, suffix, or older-version-like cases where useful.
- Temporal tests cover every component boundary, Gregorian validity, structural leap seconds, nanoseconds, known and unknown offsets, civil and instant comparison, and every successful or rejected core-time conversion without machine timezone state.
- Diagnostics tests compare structured values, not formatted messages. They cover every package-defined configuration, lexical, grammar, value, definition, data, limit, codec, allocator, and writer category that can be produced.
- Diagnostic coordinate tests include ASCII, multibyte Unicode, TAB, LF, CRLF, malformed UTF-8, decoded/source-width differences, related definitions, EOF ranges, long keys, and paths beyond bounded snapshot capacity.
- Semantic lifecycle tests distinguish initialized empty owners from zero values and cover clone independence, destroy idempotence, retained allocators, lookup borrow rules, set replacement/append, stable remove/reinsert order, local and root-relative depth, and malformed caller trees.
- Canonical byte goldens cover empty output, root assignment layout, quoted keys, escaping, arrays, inline tables, every scalar edge, all temporal forms, float fixed/scientific selection, insertion/field/array/map order, and LF output on every platform.
- Semantic parse/unparse and typed marshal share golden expectations where their represented semantic values are equal, proving one canonical spelling policy.
- Independent exact-rational parsing tests prove decimal-to-binary64 conversion, including adjacent values, halfway ties, subnormals, signed underflow, and finite overflow.
- Canonical binary64 output is checked against the pinned test-only Ryu oracle at commit `4c0618b0e44f7ef027ebae05d2cc7812048f7c8f` and named edge vectors. Runtime package code does not link the oracle or another TOML implementation.
- Property tests use deterministic replayable generators over valid semantic trees and supported application values. They prove semantic round trips, canonical byte idempotence, allocated/writer identity, clone independence, repeated determinism, typed represented-value round trips, and paired-codec contracts.
- Reflection tests use comprehensive matrices across supported and rejected scalar kinds, named/distinct forms, struct fields, anonymous flattening, tags, omission, map keys and values, arrays, slices, dynamic arrays, pointers, optional unions, `any`, unsupported kinds, root shapes, and active cycles.
- Typed-unmarshal tests prove that all preflight failures leave destinations unchanged, matched owning slots reject nonzero state, missing and ignored fields remain untouched, unknown-field policy is recursive, and installation failures leave only documented cleanable commits.
- A dedicated ownership-provenance test starts with missing or ignored fields owned by a different allocator, proves they remain untouched, cleans only package-installed matched units, and verifies neither allocator receives a foreign free.
- Codec tests cover registry lifecycle, invalid state, duplicate directional registration, independent directions, growth failure, exact-type precedence, wrapper lookup, omission order, map-key exclusion, exact-once callback order, caching, user data, returned-value validation, transactional unmarshal slots, exact external errors, callback codes, diagnostic paths/ranges, and concurrent frozen reads.
- Allocator tests wrap tracking with deterministic failure at every allocation, nonzero allocation, resize, and nonzero resize ordinal. They first measure a success path, then fail each ordinal and one ordinal beyond the final allocation.
- Fail-at-N sweeps cover every owner-producing or scratch-allocating workflow and enough shaped inputs to enter parsing text/container/definition phases, all clone alternatives, table append/replace, semantic and typed output, map sorting, codec values, typed installation containers/wrappers, and registry growth.
- Every allocation failure asserts the exact external error, correct zero or partial-result contract, unchanged transactional source/target, no preflight writer calls, and no package leak after documented cleanup.
- Allocator suites run with the default heap, tracking heap, fail-at-N wrapper, rejecting ambient allocator, feature-reporting external-lifetime arena, and unsupported-feature-reporting external-lifetime branch.
- Writer tests use a scripted writer and inject every valid or invalid count/error combination at every observed call ordinal. They prove no retries, exact error precedence, canonical accepted prefix, no writes before preflight success, cleanup after I/O failure, and zero calls for empty output.
- Ordinary randomized tests run at least 4,096 arbitrary-byte cases and 2,048 valid-seed mutations per invocation with reported replay seeds. Accepted inputs are subjected to semantic and canonical round-trip properties; rejected inputs must be leak-free and panic-free.
- Coverage-guided fuzz targets cover arbitrary strict parse, valid-UTF-8 parser mutations, parse/unparse composition, semantic lifecycle and writer validation, representative typed/codec flows, and malformed conformance-adapter input. Pull requests run a sanitizer-backed aggregate smoke campaign of at least 300 seconds spanning every target.
- Every minimized fuzz, sanitizer, allocator, writer, or conformance defect becomes a deterministic regression fixture before closure.
- The complete public suite runs on Linux amd64/arm64, macOS amd64/arm64, and Windows amd64 in normal strict-vet/style/warnings mode and optimized speed mode with bad-memory failure enabled.
- AddressSanitizer runs where supported. A frozen-registry concurrent-read stress test runs under ThreadSanitizer on a supported Linux target.
- Initial acceptance contains no line-coverage percentage or performance threshold. Benchmarks and encoded-size measurements are reproducible non-gating baselines recorded only after correctness gates pass.
- Release acceptance requires the pinned compiler, TOML corpus, and float oracle provenance; green normal, speed, sanitizer, race, and platform results; conformance reports; property/fuzz seeds; allocator and writer sweep evidence; and no unresolved skips, expected failures, sanitizer findings, memory reports, or minimized fuzz defects.

## Out of Scope

- Preserving comments, whitespace, source order trivia, quote choice, radix, separators, exact fractional digit count, or any concrete syntax tree for lossless editing.
- Filesystem convenience procedures or streaming `io.Reader` decoding.
- Partial-document parsing, parser recovery, permissive duplicates, UTF-8 replacement, TOML 1.0 mode, legacy compatibility, or nonstandard extensions.
- Schema validation, configuration merging, environment expansion, defaulting, or application-specific policy beyond typed projection.
- Public tokenizers, parser state, builders, iterators, reflected setters, path mutation, standalone semantic validators, or raw syntax callbacks.
- Header, dotted-key, or array-of-table-header generation in canonical output.
- Timezone database lookup, machine-local timezone inference, calendar arithmetic, broad temporal text parsing/formatting, or invention of missing dates, times, or offsets.
- Historical IERS validation of leap-second placement.
- Map-key codecs, raw TOML codec output, package-global codec registration, callback re-entry helpers, or mutation-safe registry concurrency.
- Generic destruction of application-defined typed destinations or a package-produced installation ledger.
- Salvaging or safely destroying arbitrary caller-created cyclic, aliased, or mixed-allocator ownership graphs.
- Compatibility guarantees for Odin revisions or targets not included in the initial supported matrix.
- An initial throughput, latency, allocation-count, encoded-size, or code-coverage pass/fail threshold.

## Further Notes

- The approved design handoff and declaration freeze remain normative for exact public names, error alternatives and payloads, callback signatures, nil-success representations, attributes, temporal conversion names, precedence rules, diagnostic lifetimes, and ownership details. If this spec is ambiguous, those approved decisions control.
- The public interface is the agreed test seam. No additional user-visible seam is required for the lexer, parser, definition state, reflection traversal, or encoder internals.
- Stage 0 may adjust declaration syntax only where required to compile on Reference Odin. Any semantic or interface change must return to design review.
- The official conformance corpus is necessary but insufficient; release requires the complete Odin-specific ownership, deterministic-output, typed-binding, writer, allocator, diagnostic, fuzz, and platform evidence.
- Correctness and ownership take priority over optimization. Benchmark-driven changes must preserve canonical bytes, error precedence, allocator behavior, and all compatibility contracts.

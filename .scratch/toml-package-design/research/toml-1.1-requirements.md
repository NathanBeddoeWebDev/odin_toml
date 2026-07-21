# Research: TOML 1.1 strict semantic tree, parser, and deterministic encoder requirements

## Summary

TOML 1.1 maps a valid UTF-8 Unicode document to a root table whose keys are strings and whose closed value set is string, integer, float, boolean, four distinct temporal types, array, and table. A strict implementation needs both the canonical ABNF for token shape and the prose rules for Unicode validity, calendar validity, losslessness, table-definition state, duplicate/redefinition rejection, and array-of-table binding; matching the grammar alone is explicitly insufficient. [Specification](https://toml.io/en/v1.1.0) · [Canonical ABNF](https://github.com/toml-lang/toml/blob/1.1.0/toml.abnf)

For an always-valid encoder, the safest semantic model is a scalar-tagged tree with unordered string-keyed tables and ordered arrays. Determinism is an implementation policy, not TOML semantics: sort table keys by one documented Unicode-scalar/UTF-8 ordering, use canonical quoted keys/basic strings and canonical scalar spellings, and emit nested tables as inline tables (including tables inside ordinary arrays) to avoid header-state ambiguities.

## Authority and terminology

- **Normative requirement** below means a rule stated by the released 1.1.0 prose specification, its linked canonical ABNF, or RFC 3339 where TOML incorporates it. The ABNF warns that some strings matching it are nevertheless invalid under the prose semantics. [ABNF preamble](https://github.com/toml-lang/toml/blob/1.1.0/toml.abnf#L1-L12)
- **Design implication** is a requirement or policy needed for this package to decode strictly, represent the result without conflation, or encode deterministically. It is not claimed to be mandated serialization style.
- TOML uses “table” for a map/hash table. The root is a nameless table. Inline tables, header-defined tables, implicit super-tables, and tables created by dotted keys all map to the same table value; syntax/definition state is required while parsing but need not survive in the semantic tree. [Objectives](https://toml.io/en/v1.1.0#objectives) · [Table](https://toml.io/en/v1.1.0#table)

## Findings

### 1. Lexical envelope and document structure

**Normative requirements**

1. TOML is case-sensitive. Whitespace is only TAB U+0009 or SPACE U+0020. A newline is only LF U+000A or CRLF U+000D U+000A; a bare CR is not a newline. The whole file must be valid UTF-8 forming a well-formed Unicode code-unit sequence. An implementation must preferably reject malformed UTF-8, or may replace malformed sequences with U+FFFD as Unicode specifies. [Preliminaries](https://toml.io/en/v1.1.0#preliminaries) · [ABNF whitespace/newline](https://github.com/toml-lang/toml/blob/1.1.0/toml.abnf#L24-L36)
2. A document is a sequence of expressions separated by newlines. An expression is blank/whitespace plus optional comment, one key/value pair, or one table header. Leading indentation is ignored. A key, `=`, and value begin on the same line, although the value grammar may span lines. A key/value pair must end at newline or EOF except that inline tables contain comma-separated key/value pairs. [Key/value pair](https://toml.io/en/v1.1.0#keyvalue-pair) · [ABNF overall structure](https://github.com/toml-lang/toml/blob/1.1.0/toml.abnf#L17-L22)
3. `#` starts a comment through end-of-line except inside strings. Comments may contain TAB, printable ASCII U+0020–U+007E, and non-surrogate Unicode; control characters U+0000–U+0008, U+000A–U+001F, and U+007F are forbidden. Comments must not alter parsed keys or values. [Preliminaries](https://toml.io/en/v1.1.0#preliminaries) · [ABNF comments](https://github.com/toml-lang/toml/blob/1.1.0/toml.abnf#L38-L44)
4. The ABNF is code-point-based after UTF-8 decoding and excludes surrogate code points U+D800–U+DFFF from `non-ascii`. A leading BOM U+FEFF is not admitted by the top-level grammar (it is neither whitespace nor a comment/key/table starter), so a strict parser rejects it. [ABNF preamble and `non-ascii`](https://github.com/toml-lang/toml/blob/1.1.0/toml.abnf#L1-L12)
5. The value token set is closed: string, integer, float, boolean, offset date-time, local date-time, local date, local time, array, and inline table. Missing/unspecified values and extra tokens after a value are invalid. [Key/value pair](https://toml.io/en/v1.1.0#keyvalue-pair)

**Design implications**

- Decode and validate UTF-8 before lexing; do not operate on arbitrary bytes. Prefer rejection rather than U+FFFD replacement for a “strict” API, because replacement destroys input identity even though the spec permits it.
- Do not use broad host-language `isspace`, identifier, number, or newline predicates. They accept characters TOML does not.
- Require complete token consumption and explicit delimiters. This rejects prefix parses such as a valid number followed by junk, two assignments on one line, bare CR, or a BOM.
- Comments and source order may be retained only in an optional concrete-syntax layer; neither belongs in the strict semantic value tree.

### 2. Keys and path semantics

**Normative requirements**

1. Bare keys are non-empty and contain only ASCII `A-Z a-z 0-9 _ -`. All-digit bare keys are strings, never numbers. Quoted keys use single-line basic-string or literal-string rules; they may be empty and may contain dots or Unicode. Multiline strings cannot be keys. Bare and quoted spellings producing the same string are equivalent. [Keys](https://toml.io/en/v1.1.0#keys) · [ABNF keys](https://github.com/toml-lang/toml/blob/1.1.0/toml.abnf#L46-L65)
2. A dotted key is two or more simple keys separated by `.`; TAB/SPACE around dots is ignored. Dots inside quoted components are data, not separators. Thus `3.14159 = "pi"` defines path `"3" → "14159"`, while `"3.14159"` is one key. [Keys](https://toml.io/en/v1.1.0#keys)
3. A key cannot be directly defined more than once. Equivalence is by decoded key path, not source spelling, so `spelling` and `"spelling"` conflict. A scalar cannot later be treated as a table, but an as-yet-undirectly-defined table path may receive more children. [Keys](https://toml.io/en/v1.1.0#keys)

**Design implications**

- Parse each key to a list of decoded Unicode strings before symbol-table lookup. Never store a dotted key as one joined string.
- Use exact, case-sensitive Unicode scalar sequences as map keys; TOML specifies no Unicode normalization or case folding. Visually/canonically equivalent Unicode spellings remain distinct unless byte/code-point equal after string escape decoding.
- An encoder can quote every key as a basic string, including empty keys, numeric-looking keys, dots, spaces, and reserved-looking text. This removes bare/dotted ambiguity. Escape each path component independently if header syntax is ever used.

### 3. Strings and Unicode

**Normative requirements**

1. All strings are sequences of Unicode characters, not bytes. Unicode escape results must be scalar values (0..10FFFF excluding D800..DFFF). Unknown escape sequences are errors. [String](https://toml.io/en/v1.1.0#string)
2. Single-line **basic strings** use `"..."`. Raw `"`, `\`, newline, and controls other than TAB are forbidden. The only escapes are `\b \t \n \f \r \e \" \\`, `\xHH`, `\uHHHH`, and `\UHHHHHHHH`; hex digits are exactly 2/4/8. `\xHH` denotes U+00HH, not a byte. [String](https://toml.io/en/v1.1.0#string) · [ABNF basic strings](https://github.com/toml-lang/toml/blob/1.1.0/toml.abnf#L67-L95)
3. **Multiline basic strings** use triple double quotes and allow newlines. Exactly one newline immediately after the opening delimiter is trimmed. Raw backslash and controls are forbidden except TAB/LF/CR, with CR only in CRLF. The basic escapes remain valid. One or two unescaped quotes may occur internally; three delimit. A line-ending backslash—an unescaped backslash that is the last non-whitespace character on a line—removes itself and all following whitespace/newlines through the next non-whitespace character or closing delimiter. [String](https://toml.io/en/v1.1.0#string) · [ABNF multiline basic](https://github.com/toml-lang/toml/blob/1.1.0/toml.abnf#L97-L109)
4. **Literal strings** use single quotes, have no escapes, are single-line, and cannot contain a single quote. TAB is the only permitted control. **Multiline literal strings** use triple single quotes, trim one immediately following newline, have no escaping, and otherwise preserve content subject to newline normalization; one or two apostrophes may occur internally, but runs of three or more cannot be content. [String](https://toml.io/en/v1.1.0#string) · [ABNF literal strings](https://github.com/toml-lang/toml/blob/1.1.0/toml.abnf#L111-L132)
5. Parsers may normalize multiline-basic newlines to the platform convention and must normalize multiline-literal newlines in the same manner. Consequently original LF versus CRLF is not semantic string information. [String](https://toml.io/en/v1.1.0#string)

**Design implications**

- The semantic string type must be valid Unicode scalar text, but may include NUL and other controls when they came from escapes. Reject surrogate-valued `\u`/`\U` escapes and values above U+10FFFF.
- A universally safe canonical encoder uses single-line basic strings and escapes `"`, `\`, all C0 controls and DEL (using named escapes where available, otherwise `\xHH`), while directly emitting other scalar values as UTF-8. It need never emit multiline or literal syntax.
- If the host string representation can contain ill-formed UTF-16 or arbitrary bytes, encoder validation must reject it rather than output invalid TOML.

### 4. Integers, floats, and booleans

**Normative requirements**

1. Decimal integers have optional `+`/`-`; leading zeros are forbidden except the single zero. `+0` and `-0` equal zero. Underscores are allowed only singly between digits. Hex `0x`, octal `0o`, and binary `0b` forms are non-negative only, require at least one radix digit, allow leading zeros after the prefix, and allow underscores only between digits (not after the prefix). `0x` uses lowercase `x` but hex digits are case-insensitive. [Integer](https://toml.io/en/v1.1.0#integer) · [ABNF integer](https://github.com/toml-lang/toml/blob/1.1.0/toml.abnf#L134-L159)
2. Implementations may choose any integer size. Supporting signed 64-bit `[-2^63, 2^63-1]` is recommended, not required. Any integer that the implementation cannot represent losslessly **must cause an error**, never wrap, saturate, or convert to float. [Integer](https://toml.io/en/v1.1.0#integer)
3. A finite float starts with a decimal integer part and has a fraction, exponent, or both in that order. A fraction is `.` plus one or more digits; the dot must have digits on both sides. An exponent is `e`/`E`, optional sign, and one or more digits; leading exponent zeros are allowed. Underscores occur only between digits. Therefore `.7`, `7.`, and `3.e20` are invalid. [Float](https://toml.io/en/v1.1.0#float) · [ABNF float](https://github.com/toml-lang/toml/blob/1.1.0/toml.abnf#L161-L179)
4. `+0.0` and `-0.0` map according to IEEE 754, so negative zero is observably distinct at the floating representation level. Specials are lowercase `inf`, `+inf`, `-inf`, `nan`, `+nan`, `-nan`; actual signaling/quiet NaN encoding is implementation-specific, and signs on NaN are syntactically valid. Float precision is implementation-selected; at least IEEE-754 binary64 is recommended, not mandatory. [Float](https://toml.io/en/v1.1.0#float)
5. Booleans are exactly lowercase `true` and `false`. [Boolean](https://toml.io/en/v1.1.0#boolean)

**Design implications**

- Use distinct integer and float variants; `1` and `1.0` are different TOML value types. Accumulate integer magnitude with checked arithmetic and range-check only after sign handling so the minimum signed value is accepted.
- A binary64 tree is conforming if documented, but decoding every accepted literal must be deliberate; unlike integers, the prose does not mandate an error merely because extra float precision is lost. A strict API should define whether finite overflow is rejected rather than silently becoming `inf`.
- Deterministic binary64 encoding: lowercase decimal, shortest round-tripping finite representation; append `.0` if the result otherwise lexes as an integer; preserve `-0.0`; emit `inf`/`-inf`; canonicalize all NaNs to `nan` unless the public model explicitly promises a sign (payload and sNaN/qNaN cannot portably round-trip).

### 5. Temporal values: four non-interchangeable types

**Normative requirements**

1. TOML has four separate types: **offset date-time** (an instant), **local date-time** (no offset/timezone), **local date**, and **local time**. Omitting an offset is not permission to infer the system timezone; conversion of a local date-time to an instant is implementation-specific. [Offset Date-Time](https://toml.io/en/v1.1.0#offset-date-time) · [Local Date-Time](https://toml.io/en/v1.1.0#local-date-time) · [Local Date](https://toml.io/en/v1.1.0#local-date) · [Local Time](https://toml.io/en/v1.1.0#local-time)
2. Shapes are RFC-3339-derived: `YYYY-MM-DD`; time `HH:MM` with optional `:SS` and then optional `.digits`; date-time separator is `T`, lowercase `t` (ABNF literals are case-insensitive), or ASCII space; offset is `Z`/`z` or `±HH:MM`. Seconds may be omitted in TOML 1.1 and semantically become `:00`; if seconds are absent, a fractional part is not admitted. [ABNF date/time](https://github.com/toml-lang/toml/blob/1.1.0/toml.abnf#L190-L230) · [1.1 changelog](https://github.com/toml-lang/toml/blob/1.1.0/CHANGELOG.md#110--2025-12-18)
3. Numeric width is fixed: four-digit year and two-digit month/day/hour/minute/second/offset fields. Semantic ranges are month 01–12; day valid for month/year; hour 00–23; minute 00–59; and second 00–58, 00–59, or 00–60 under leap-second rules. The grammar’s comments and incorporated RFC 3339 semantics require calendar validation beyond matching digits. [ABNF date/time](https://github.com/toml-lang/toml/blob/1.1.0/toml.abnf#L190-L211) · [RFC 3339 §5.6](https://www.rfc-editor.org/rfc/rfc3339#section-5.6)
4. Offset and local date-time/local-time permit arbitrary positive fractional-second digit counts. Implementations must support at least millisecond precision. If supplied precision exceeds supported precision, extra digits **must be truncated, not rounded**. [Offset Date-Time](https://toml.io/en/v1.1.0#offset-date-time) · [Local Date-Time](https://toml.io/en/v1.1.0#local-date-time) · [Local Time](https://toml.io/en/v1.1.0#local-time)
5. RFC 3339 permits leap second `60` only at a leap-second instant (normally the end of June or December, expressed relative to the offset), and `-00:00` conventionally means an unknown local offset. The TOML grammar admits both `:60` and `-00:00`; a parser claiming RFC-3339 validation cannot simply rely on a host timestamp type that rejects them. [RFC 3339 §§4.3, 5.6](https://www.rfc-editor.org/rfc/rfc3339)

**Design implications**

- Give all four forms distinct semantic variants. Do not turn local forms into instants, and do not represent dates/times as unvalidated strings.
- A temporal structure needs calendar fields, optional offset for only the offset-date-time variant, a fractional unit/scale or a documented fixed precision, and a leap-second policy. With fixed precision, truncate at decode exactly as required.
- If offset date-time is normalized to an instant, original separator, omitted seconds, fraction digit count, `Z` versus `+00:00`, and original numeric offset are syntax rather than semantic data. However, normalizing `-00:00` to UTC erases RFC 3339’s “unknown offset” distinction; preserve an offset-kind flag or reject/document this representational limitation.
- A safe canonical encoder emits seconds always, `T`, uppercase `Z` for known UTC, fixed-width validated fields, and only as many fractional digits as the model supports (trim trailing zeros deterministically, omitting the fraction if zero). Leap second values require a formatter that permits `60`.

### 6. Arrays

**Normative requirements**

1. Arrays are ordered and enclosed in `[]`; commas separate values. Any value type is allowed and different types may be mixed, including integer with float, nested arrays, and inline tables. Empty arrays are valid. [Array](https://toml.io/en/v1.1.0#array)
2. Arrays may span lines and may have one trailing comma. Any number of allowed newlines/comments may appear before values, commas, and `]`; TAB/SPACE indentation is ignored. A comma is still required between adjacent values. [Array](https://toml.io/en/v1.1.0#array) · [ABNF array](https://github.com/toml-lang/toml/blob/1.1.0/toml.abnf#L232-L246)

**Design implications**

- Preserve array order exactly and impose no homogeneity check. “Array of tables” is semantically an array whose elements are tables; syntactic origin need not be a separate semantic type unless source-preserving re-encoding is a goal.
- Canonical output can use ordinary arrays with inline-table elements. A fixed spacing/no-comments/no-trailing-comma policy is deterministic and always valid.

### 7. Tables, dotted-key definition state, and duplicates

**Normative requirements**

1. Tables are string-keyed collections. Header `[path]` selects that table until the next header/EOF. Header component syntax and whitespace rules equal key syntax. Empty tables are valid. Key/value pairs within a table have **no guaranteed order**. The root table exists from BOF, is nameless, and cannot be relocated. [Table](https://toml.io/en/v1.1.0#table)
2. A standard header defines its final table and implicitly creates missing super-tables. Implicitly created super-tables may be explicitly defined later: `[x.y.z.w]` followed by `[x]` is valid. A table itself may not be defined twice, and a value/table kind cannot be changed. [Table](https://toml.io/en/v1.1.0#table)
3. A dotted key/value assignment is stricter: every component before the last creates **and defines** a table. Those table contents must be defined entirely within the current standard-table block, entirely in the root before headers, or entirely within one inline table. Such a dotted-defined table cannot later be redefined with `[table]`, nor can dotted keys redefine a table already defined in header form. A new sub-table below a dotted-defined table may still be introduced by header. [Table, dotted keys](https://toml.io/en/v1.1.0#table)
4. Duplicate/redefinition checks apply to decoded full paths, including collisions between bare/quoted keys and between direct, dotted, header, inline-table, and array-of-table forms. Once a path is a scalar/array/inline table/standard table/AoT, incompatible reuse is invalid. Out-of-order dotted-key and standard-table definitions are discouraged but valid except for the AoT parent-order rule below. [Keys](https://toml.io/en/v1.1.0#keys) · [Table](https://toml.io/en/v1.1.0#table)

**Design implications**

- During parsing, each table node needs transient provenance/state at least equivalent to: absent, implicitly created/undefined, explicitly defined by standard header, defined by dotted key, sealed inline table, array-of-tables, or non-table value. A final map alone cannot enforce all legal transitions.
- Resolve assignments relative to the current table (or current AoT element), then check every path prefix before mutation. Diagnostics should distinguish duplicate leaf, scalar-as-table, table redefinition, sealed-inline extension, and array/table collision.
- Table order is not semantic. If the in-memory map preserves insertion order, APIs must not imply that TOML gives it meaning. A deterministic encoder should sort keys independently at every table; document the comparator (for example, lexicographic Unicode scalar value, equivalently UTF-8 byte order for scalar strings).

### 8. Inline tables

**Normative requirements**

1. `{}` contains zero or more comma-separated normal-form key/value pairs; all value types, dotted keys, and nested inline tables are allowed. TOML 1.1 permits newlines, comments, and one trailing comma in inline tables. [Inline Table](https://toml.io/en/v1.1.0#inline-table) · [ABNF inline table](https://github.com/toml-lang/toml/blob/1.1.0/toml.abnf#L259-L269)
2. An inline table is fully self-contained: all its keys and sub-tables are defined and sealed inside its braces. Nothing outside may add to it, and an inline table cannot be used later to add members to an already-defined table. Duplicate paths inside remain invalid. [Inline Table](https://toml.io/en/v1.1.0#inline-table)
3. Newlines/trailing commas, `\xHH`, `\e`, and omitted temporal seconds are specifically 1.1 changes; a 1.0-only parser will reject some valid 1.1 output. [1.1 changelog](https://github.com/toml-lang/toml/blob/1.1.0/CHANGELOG.md#110--2025-12-18) · [toml-test version selection](https://github.com/toml-lang/toml-test/blob/main/version.go)

**Design implications**

- Parse inline contents in an isolated table-definition scope, run all ordinary dotted/duplicate rules there, then mark the resulting node sealed in parser state.
- Encoding every non-root table as an inline table is semantically complete and avoids forward/redefinition problems. For maximum compatibility the deterministic encoder can still emit inline tables on one line without a trailing comma, even though 1.1 permits both.

### 9. Arrays of tables and their ordering-sensitive rules

**Normative requirements**

1. `[[path]]` creates an array at the path on first use and appends a newly defined table element on each subsequent identical header. Element order is encounter order. A reference through that AoT path binds to its **most recently defined element**, enabling standard sub-tables and nested AoTs under it. [Array of Tables](https://toml.io/en/v1.1.0#array-of-tables)
2. If a table/AoT parent is an array element, that element must already exist before its child is defined. Reversing the order is a parse-time error because the child has no element to attach to. This is the material exception to otherwise order-insensitive table definitions. [Array of Tables](https://toml.io/en/v1.1.0#array-of-tables)
3. `[[x]]` may not append to a statically assigned array, even `x = []`. A normal table cannot reuse an AoT/array path, an AoT cannot redefine a normal table, and a standard table cannot replace a nested AoT (or vice versa). All are parse-time errors. [Array of Tables](https://toml.io/en/v1.1.0#array-of-tables)
4. A child standard table under an AoT belongs to the latest parent element only; a later parent `[[...]]` changes the binding target. Fully qualified paths are still required—headers are not lexically nested merely because they follow one another. [Array of Tables](https://toml.io/en/v1.1.0#array-of-tables)

**Design implications**

- Parser state for an AoT path must hold the ordered elements and a current/latest element. Path resolution crossing an AoT descends through that current element; failure when none exists is immediate.
- Repeated identical `[[path]]` is the one intentional repeated header form and must not be rejected as an ordinary duplicate table.
- A semantic encoder may serialize an AoT as `[ { ... }, { ... } ]`, preserving array order while eliminating current-element binding hazards. If human-oriented `[[...]]` output is later added, it needs a dependency-aware traversal and cannot merely sort all headers globally.

### 10. Decision-ready semantic tree and canonical encoding contract

**Required semantic variants**

```text
Value = String(valid Unicode scalar text)
      | Integer(chosen lossless bounded or arbitrary-precision domain)
      | Float(chosen precision; includes ±0, ±inf, NaN)
      | Boolean
      | OffsetDateTime
      | LocalDateTime
      | LocalDate
      | LocalTime
      | Array(ordered Value list)
      | Table(unordered map<String, Value>)
Document = Table
```

This preserves every TOML semantic distinction. Syntax style, comments, whitespace, key spelling, number radix/underscores, quote form, table-header origin, and non-AoT table insertion order are not semantic and need a separate CST if round-trip source fidelity is desired.

**Recommended always-valid deterministic encoder profile (design policy)**

1. Validate the entire tree before writing: scalar Unicode only; supported integer/float domains; valid calendar/offset/time fields; table-only root; no impossible host values.
2. Emit one root key/value per line. Sort each table by decoded key using one fixed documented comparator. Quote every key with single-line basic-string syntax.
3. Emit every nested table as a single-line inline table and every array as ordinary `[...]`; tables in arrays are inline tables. Recursively sort inline-table keys. This representation avoids table/AoT definition transitions and is valid for all tree shapes.
4. Use canonical single-line basic strings and escapes; lowercase `true`/`false`; decimal integers without `+`, leading zeros, or underscores; canonical float rules from Finding 4; fixed-width canonical temporal rules from Finding 5.
5. Use fixed ASCII spaces (for example `key = value`, `[a, b]`, `{ "k" = v }`), LF line endings, no comments, no trailing commas, and a final LF by policy. None of these formatting choices changes TOML semantics.
6. Make recursion/depth, collection-size, and output-size failures explicit. Cyclic/shared-reference host graphs are not TOML trees; reject cycles rather than recurse forever. Aliasing need not be preserved.

This profile is deterministic only after the integer/float/time precision domains and key comparator are frozen in the public contract. It intentionally canonicalizes NaNs, offsets (subject to `-00:00` handling), and syntax trivia.

## Ambiguous and adversarial edge-case checklist

A strict parser/test plan should include at least:

- malformed UTF-8; BOM; bare CR; Unicode whitespace outside strings; forbidden comment controls; `#` inside strings;
- empty quoted key versus empty bare key; quoted dot versus path dot; numeric-looking dotted key; bare/quoted duplicate; canonically equivalent but code-point-distinct Unicode keys;
- reserved escapes, short/long hex escapes, surrogate and >U+10FFFF escapes, raw controls, triple-quote boundary runs, multiline initial-newline trim, and line-ending-backslash folding;
- signed radix integers, decimal leading zeros, misplaced/repeated underscores, int overflow, float dot boundaries, uppercase `INF/NAN`, negative zero, overflow/subnormal/NaN policy;
- invalid leap day/month/day/time/offset, lowercase `t`/`z`, omitted seconds, fraction without seconds, long fraction truncation, leap second, `-00:00`, and four-way temporal type distinction;
- missing commas, double commas, comments/newlines around array and inline-table separators, heterogeneous arrays, and 1.1 inline trailing comma;
- duplicate paths through different spellings/forms; scalar-prefix collision; implicit-header super-table later definition (valid) versus dotted-defined table later header (invalid); extending sealed inline tables;
- static array versus AoT; standard table versus AoT; nested AoT before parent (invalid); repeated AoT append (valid); subtable binding to latest element; empty AoT elements;
- reordered ordinary tables/dotted keys (valid) versus reordered AoT-dependent children (invalid).

The first-party language-agnostic suite explicitly separates 1.1 fixtures and excludes former 1.0-invalid cases now made valid; conformance should run `toml-test` in 1.1 mode, not its historical/default 1.0 selection. [toml-test README](https://github.com/toml-lang/toml-test/blob/main/README.md) · [1.1 file manifest](https://github.com/toml-lang/toml-test/blob/main/tests/files-toml-1.1.0) · [version rules](https://github.com/toml-lang/toml-test/blob/main/version.go)

## Sources

### Kept

- [TOML: English v1.1.0](https://toml.io/en/v1.1.0) — released first-party normative prose; primary authority for semantic and conformance rules.
- [toml.abnf at tag 1.1.0](https://github.com/toml-lang/toml/blob/1.1.0/toml.abnf) — first-party canonical lexical grammar, pinned to the release tag.
- [TOML CHANGELOG 1.1.0](https://github.com/toml-lang/toml/blob/1.1.0/CHANGELOG.md#110--2025-12-18) — first-party identification of 1.1 deltas and clarifications.
- [RFC 3339](https://www.rfc-editor.org/rfc/rfc3339) — primary standard incorporated by the TOML temporal sections.
- [toml-test README, 1.1 manifest, and version rules](https://github.com/toml-lang/toml-test) — first-party language-neutral conformance evidence and exact version partitioning.

### Dropped

- TOML 1.0 pages and third-party parser documentation — stale for `\e`, `\xHH`, omitted seconds, and multiline/trailing-comma inline tables.
- Search-result commentary and SEO tutorials — redundant and less authoritative than the released spec/grammar.
- Open GitHub issues as normative authority — useful historical discussion but not released requirements; the final brief relies on merged 1.1 text and tagged files.

## Gaps and residual risks

1. **RFC 3339 edge semantics:** TOML says offset date-time represents an instant while its ABNF admits RFC 3339 `-00:00` (unknown offset), and host libraries vary on leap seconds/year 0000. The package must explicitly choose representations and add direct tests; silently normalizing these cases is the largest semantic risk.
2. **Float conversion:** TOML permits implementation-selected precision and does not fully prescribe overflow/underflow conversion behavior. Freeze an f64 conversion/error policy and verify it against `toml-test` plus boundary tests.
3. **Deterministic order is package policy:** TOML tables are unordered and specify no canonical serialization. The key comparator and scalar canonicalization rules must be documented and locked with golden tests.
4. **Conformance suite is necessary but not sufficient:** the ABNF itself says prose-invalid inputs can match. Add state-transition tests for dotted/header/inline/AoT collisions in addition to running the complete first-party 1.1 suite.

## Review findings

- **high — `.scratch/toml-package-design/issues/02-extract-toml-1-1-requirements.md`:** implementation design must not use the ABNF as the sole validator; calendar, lossless integer, duplicate, sealed-inline, and table/AoT state rules are semantic checks.
- **high — future semantic-tree API:** four temporal variants and integer/float distinction are mandatory to avoid lossy conflation; leap second and `-00:00` need an explicit decision.
- **medium — future encoder:** deterministic table order and NaN/offset canonicalization are not supplied by TOML and must be package-level contracts.
- **no source or tracker files modified.** Only this research artifact was created.

```acceptance-report
{
  "criteriaSatisfied": [
    {
      "id": "criterion-1",
      "status": "satisfied",
      "evidence": "Decision-ready normative requirements, design implications, severity-tagged findings, file paths, primary-source citations, and residual risks are recorded in .pi-subagents/artifacts/outputs/7f1ac1c7-460f-4868-946d-126b5276b428/.scratch/toml-package-design/research/toml-1.1-requirements.md."
    }
  ],
  "changedFiles": [
    ".pi-subagents/artifacts/outputs/7f1ac1c7-460f-4868-946d-126b5276b428/.scratch/toml-package-design/research/toml-1.1-requirements.md"
  ],
  "testsAddedOrUpdated": [],
  "commandsRun": [
    {
      "command": "Primary-source web research and direct fetch of TOML 1.1 prose, tagged ABNF/changelog, RFC 3339, and toml-test version metadata",
      "result": "passed",
      "summary": "Authoritative sources were retrieved and cross-checked; no project commands were required for this research-only task."
    }
  ],
  "validationOutput": [
    "Covered lexical rules, Unicode, keys, all string forms, integers/floats/booleans, all four temporal forms, arrays, tables, dotted keys, inline tables, arrays of tables, ordering, duplicates/redefinitions, ambiguous edges, and deterministic encoding implications.",
    "Source/tracker files were not edited."
  ],
  "residualRisks": [
    "RFC 3339 leap-second, year-0000, and -00:00 support varies across host time libraries and needs an explicit representation policy.",
    "Float overflow/underflow and deterministic conversion require a package-level f64 policy because TOML leaves precision implementation-defined.",
    "TOML does not define canonical table ordering; the encoder comparator must be frozen and golden-tested."
  ],
  "noStagedFiles": true,
  "diffSummary": "Added one research artifact only; no source, test, issue, or tracker file changes.",
  "reviewFindings": [
    "high: .scratch/toml-package-design/issues/02-extract-toml-1-1-requirements.md - ABNF-only validation would miss mandatory semantic rejection rules.",
    "high: future semantic-tree API - preserve integer/float and all four temporal distinctions; decide leap-second and unknown-offset representation.",
    "medium: future encoder - define deterministic key ordering and NaN/offset canonicalization as package policy."
  ],
  "manualNotes": "Research artifact written to the authoritative runtime output path; no source or tracker files were modified."
}
```

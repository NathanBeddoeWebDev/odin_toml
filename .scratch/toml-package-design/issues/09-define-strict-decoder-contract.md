# Define the strict decoder and diagnostic contract

Type: grilling
Status: resolved
Blocked by: 02, 05, 07, 08

## Question

How should complete-document tokenization and parsing enforce TOML 1.1 definition rules, construct the semantic tree, apply nesting limits, classify errors, report byte/line/column and key paths, handle invalid UTF-8 and allocation failures, and guarantee cleanup without introducing a public streaming reader API?

## Answer

Use a private allocation-free pull lexer with bounded lookahead over the borrowed complete input, followed by a private recursive-descent parser that constructs the owned semantic tree transactionally. Tokens and source lexemes borrow the input only during the call. Do not materialize a complete token array and do not expose a tokenizer, parser, recovery API, validator, or streaming reader. A successful parse must consume the complete document through EOF; a valid token prefix is never sufficient.

### Public parse contract and options

`parse_bytes` and `parse_string` have identical semantics, including UTF-8 validation for Odin `string` input. They borrow their input, take `Parse_Options` by value with a `{}` default, select an allocator and caller location as established in issues 05 and 08, and return either one initialized `Document` owner or one `Parse_Error`. Their exact public shapes are:

```odin
parse :: proc {
    parse_bytes,
    parse_string,
}

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

Parse_Options :: struct {
    max_depth: int, // 0 selects 128
}
```

Apply `@(require_results)` to both procedures. Empty, whitespace-only, and comment-only documents succeed with an initialized empty root table. No input bytes or parser state escape in either the document or error.

Keep parse policy intentionally narrow.

The parser always accepts strict TOML 1.1. There are no permissive, UTF-8-replacement, duplicate-key, version-selection, comment-retention, number-coercion, or recovery modes. `max_depth == 0` selects 128; explicit values may be `1..256`; 256 is the package hard maximum. Reject another value before input processing. Define depth as semantic path length from the root: the root table has depth zero and every table-key or array-index segment adds one. Reject a child before allocating or installing it when that next segment would exceed the selected depth. Do not impose separate fixed limits on document bytes, lexeme length, decoded string length, table entries, or array elements; check all size arithmetic and report representational exhaustion or allocator failure instead.

### Decode pipeline and lexical envelope

Apply this order:

1. Reject an allocator whose procedure is nil, then validate options. This order fixes precedence when both are invalid.
2. Perform an allocation-free whole-input UTF-8 preflight. Reject the first malformed byte sequence; never replace it with U+FFFD. Because valid Unicode scalar text is the lexical prerequisite, malformed UTF-8 anywhere in the input takes precedence over TOML syntax errors.
3. Initialize the root table and private parse state with the selected allocator.
4. Pull tokens lazily, decode values, and apply definition transitions while constructing the semantic tree.
5. Require expression termination and final EOF, then discard all transient definition and lookup state before transferring the document owner.

The lexer recognizes only TOML TAB/SPACE whitespace and LF/CRLF newlines. Bare CR, BOM, Unicode lookalike whitespace, forbidden comment controls, unknown escapes, raw forbidden string controls, and source characters outside the TOML grammar are errors. It validates comments even though comments are discarded. It tracks punctuation and complete scalar/key/string spans without exposing token kinds publicly. Context-specific key and value scanning is allowed, including the ASCII-space date-time separator, but scalar recognition must consume the entire candidate through a legal TOML delimiter so malformed suffixes cannot be accepted as trailing input or as a valid prefix.

Decode strings and keys to independently owned UTF-8 text; even unescaped text must not alias the input. Validate escape results as Unicode scalar values. Apply TOML multiline opening-newline trimming and line-ending-backslash folding before installing the value. For raw newlines retained in multiline basic and multiline literal strings, use the Odin compile target's platform newline convention consistently: normalize LF and CRLF to CRLF for a Windows target and to LF for every other target. Escaped `\r` and `\n` keep their explicit decoded meanings, and bare CR remains invalid.

Accumulate integers with checked arithmetic into the exact `i64` domain, including `-9223372036854775808`; never wrap, saturate, or convert an overflowing integer to float. Convert syntactically valid finite floats to correctly rounded IEEE-754 `f64`, preserve positive and negative zero, and accept subnormals and underflow to signed zero. Reject a finite literal that converts to infinity as `Float_Out_Of_Range`; only explicit TOML infinity spellings produce infinities. Normalize `nan`, `+nan`, and `-nan` to one host quiet NaN without promising source sign or payload. Decode temporals exactly as issue 06 specifies, including calendar validation, omitted seconds, nanosecond truncation, leap second preservation, and unknown `-00:00` offset. Arrays remain ordered and heterogeneous; TOML 1.1 newlines and trailing commas in arrays and inline tables are accepted exactly where the grammar allows them.

### Semantic construction and definition state

Construct semantic entries at the point they first come into existence so the insertion-order rules from issue 07 hold. The parser may maintain transient hash lookup state, but the public ordered entry sequence remains the sole semantic table representation. Parser lookup and definition metadata use the selected allocator and stable private node IDs rather than pointers into resizable `Table` or `Array` storage.

Maintain a private sidecar definition graph that distinguishes at least:

- the root table;
- an implicitly created table;
- a standard-header-defined table;
- a dotted-key-defined table;
- a sealed inline table and its sealed descendants;
- a scalar or statically assigned array;
- an array-of-tables container;
- each array-of-tables element and the container's latest element;
- the source range that created a node, its optional explicit-definition range, every AoT element header range, and the component ranges of the header that selected the active table.

The root table is initially active. Key/value assignments resolve relative to the active table. Standard and AoT header paths are always root-qualified; accepting `[path]` makes that table active, and accepting `[[path]]` makes the newly appended table element active. Parsing an inline table uses an isolated local active table and restores, without changing, the outer active table when the inline value closes.

Resolve decoded paths component by component and validate the complete applicable transition before treating it as a legal definition. Missing standard-header parents become implicit tables; the final implicit table may later be defined once by a standard header. Only missing intermediate tables created by a dotted key become dotted-defined. Traversing an existing implicit, header-defined, dotted-defined, or AoT-element table with a dotted key does not reclassify that table. A dotted-created table cannot later be redefined as that table, although a new child table may be defined beneath it where TOML permits it. Inline tables are built in an isolated definition scope and their complete subtree is sealed when the closing brace is accepted. A scalar, static array, or sealed inline subtree can never be traversed as an extensible table.

Resolve every `[[path]]` afresh from the root, selecting the latest element each time a parent AoT is crossed. At the resulting parent node, create the leaf semantic array and append its first table when absent, or append to that leaf only when it is already the AoT container at that resolved semantic location. Identical textual nested-AoT headers may therefore reach different leaf containers after an outer AoT appends; they must never be associated by decoded textual path alone. Because creating an AoT also creates its first element, there is no persistent empty-AoT parser state: source that defines an apparent child before later declaring its parent as an AoT is rejected when that later declaration conflicts with the already established normal-table path. Reject a static array used as an AoT, a normal table used as an AoT, an AoT used as a normal table, and every incompatible source-definition transition. AoT provenance and latest-element state are discarded after success, leaving an ordinary semantic `Array` of `Table` values.

Reject decoded-path duplicates regardless of bare/quoted spelling, scalar-as-table traversal, repeated standard tables, dotted/header redefinitions, extension of sealed inline tables, and table/array/AoT conflicts. Definition failures identify the attempted path and retain the first conflicting definition's range for diagnostics. Parser mutations need not roll back individually because any parse failure destroys the complete unpublished document, but every temporary owner must always be registered for cleanup before another fallible operation.

### Error model

Return exactly one allocation-free error; do not recover or aggregate diagnostics. Stateful TOML interpretation makes diagnostics after the first failure unreliable. Use a normal union, whose nil state means success, because the payload-bearing `Parse_Diagnostic` cannot participate in Odin's `#shared_nil` representation:

```odin
Parse_Configuration_Error :: enum u8 {
    Invalid_Allocator,
    Invalid_Max_Depth,
}

Parse_Encoding_Error :: enum u8 {
    Invalid_UTF8,
}

Parse_Lexical_Error :: enum u8 {
    Illegal_Character,
    Invalid_Newline,
    Invalid_Comment_Character,
    Unterminated_Basic_String,
    Unterminated_Literal_String,
    Invalid_String_Character,
    Invalid_Escape,
    Invalid_Unicode_Escape,
    Invalid_Bare_Key,
}

Parse_Syntax :: enum u8 {
    End_Of_Input,
    End_Of_Line,
    Key,
    Equals,
    Value,
    Dot,
    Comma,
    Left_Bracket,
    Right_Bracket,
    Left_Brace,
    Right_Brace,
    Table_Header,
    Array_Of_Tables_Header,
    Expression_End,
    Other,
}

Parse_Syntax_Set :: distinct bit_set[Parse_Syntax]

Parse_Grammar_Error :: struct {
    expected: Parse_Syntax_Set,
    found:    Parse_Syntax,
}

Parse_Value_Error_Kind :: enum u8 {
    Invalid_Integer,
    Integer_Out_Of_Range,
    Invalid_Float,
    Float_Out_Of_Range,
    Invalid_Boolean,
    Invalid_Temporal,
    Invalid_Value,
}

Parse_Value_Error :: struct {
    kind:           Parse_Value_Error_Kind,
    temporal_error: temporal.Error, // non-.None only for Invalid_Temporal
}

Parse_Definition_Form :: enum u8 {
    Key_Value,
    Implicit_Table,
    Standard_Table,
    Dotted_Table,
    Inline_Table,
    Static_Array,
    Array_Of_Tables,
    Array_Of_Tables_Element,
}

Parse_Definition_Error_Kind :: enum u8 {
    Duplicate_Key,
    Non_Table_Path_Component,
    Table_Redefined,
    Dotted_Table_Redefined,
    Inline_Table_Extended,
    Table_Array_Conflict,
    Array_Of_Tables_Conflict,
}

Parse_Definition_Error :: struct {
    kind:      Parse_Definition_Error_Kind,
    existing:  Parse_Definition_Form,
    attempted: Parse_Definition_Form,
}

Parse_Limit_Error :: enum u8 {
    Maximum_Depth_Exceeded,
    Size_Overflow,
}

Parse_Diagnostic_Detail :: union #no_nil {
    Parse_Encoding_Error,
    Parse_Lexical_Error,
    Parse_Grammar_Error,
    Parse_Value_Error,
    Parse_Definition_Error,
    Parse_Limit_Error,
}

Optional_Source_Range :: struct {
    value: Source_Range,
    ok:    bool,
}

Parse_Diagnostic :: struct {
    detail:  Parse_Diagnostic_Detail,
    primary: Source_Range,
    related: Optional_Source_Range,
    path:    Parse_Diagnostic_Path,
}

Parse_Error :: union {
    Parse_Configuration_Error,
    Parse_Diagnostic,
    runtime.Allocator_Error,
}
```

A nil `Parse_Error` is the only success state. The runtime `.None` value is never installed as an allocator-error variant. `Invalid_Allocator` is reserved for a nil allocator procedure; non-nil allocators propagate the exact `runtime.Allocator_Error` they return.

Keep private lexer token kinds and parser-procedure names out of the API. The exact detail alternatives above distinguish source encoding, lexical form, ordinary expected/found grammar, scalar value, TOML definition, and resource limits. The grammar categories describe source punctuation or semantic expectations rather than lexer implementation tokens. A temporal-looking scalar that has temporal shape but invalid components reports `Invalid_Temporal` and the applicable `temporal.Error`; a scalar that cannot be classified into any TOML value form reports `Invalid_Value`.

Failure selection is deterministic:

1. nil allocator procedure, then invalid `max_depth`;
2. malformed UTF-8 found by whole-input preflight;
3. the first lexical, grammar, value, definition, or limit error encountered in source order;
4. an allocator error whenever allocation failure prevents continued parsing.

Allocation errors do not need a synthetic source location because scratch growth and semantic allocation need not correspond to one unambiguous token. Propagate the exact allocator error rather than collapsing every failure to out-of-memory. Allocator-contract violations encountered after individual release has already succeeded remain programming errors under issue 08 and do not replace the original parse failure.

### Source coordinates and ranges

Use source coordinates with these semantics:

```odin
Source_Position :: struct {
    byte:   int, // zero-based UTF-8 byte offset
    line:   int, // one-based
    column: int, // one-based Unicode-scalar column
}

Source_Range :: struct {
    start: Source_Position,
    end:   Source_Position, // half-open
}
```

Tabs count as one scalar column; columns are not grapheme, terminal-cell, or tab-stop counts. CRLF advances one line and the next source scalar is column one. Coordinates always describe original source spelling before escape decoding or multiline newline normalization. EOF expectations use an empty range at `len(input)`. Byte offsets are authoritative for source slicing.

Validate UTF-8 according to RFC 3629 shortest-form scalar sequences. The malformed-input primary range is exactly the first byte of the first ill-formed sequence: an invalid leading byte or stray continuation diagnoses that byte; a bad continuation, overlong form, surrogate encoding, value above U+10FFFF, or truncated sequence diagnoses the sequence's leading byte. Set `end.byte = start.byte + 1`; because the byte is not a Unicode scalar, retain `start.line` and `start.column` unchanged in the end position. Line and column count only the valid scalar prefix before that byte. This convention is deterministic even when the byte that first proves a bad continuation is an ASCII CR or LF later in the attempted sequence.

The primary range is otherwise the smallest span that conclusively demonstrates the error: the offending bytes for an invalid character, escape, or digit; an empty insertion point for a missing delimiter; a known malformed scalar subpart when available; the complete scalar for representational overflow or a semantically invalid temporal; and the conflicting key/header component for a definition failure. A definition diagnostic carries as its related range the source occurrence that established the incompatible state: the prior direct leaf definition for a duplicate, the explicit definition rather than earlier legal implicit creation for a repeated table, the value definition for a non-table prefix, the inline-table definition for sealed extension, or the first incompatible static-array/table/AoT definition for a kind conflict. AoT elements retain their own header ranges; do not use the container's first range when a particular element caused the conflict.

### Diagnostic paths

A parse path is a bounded structured snapshot, not an owning `Path` allocation and not a borrow from the input or destroyed partial document. Its exact storage contract is:

```odin
PARSE_DIAGNOSTIC_PATH_CAPACITY     :: 32
PARSE_DIAGNOSTIC_PATH_PREFIX_COUNT :: 8
PARSE_DIAGNOSTIC_KEY_CAPACITY      :: 64
PARSE_DIAGNOSTIC_KEY_PREFIX_BYTES  :: 32

Source_Byte_Range :: struct {
    start: int,
    end:   int, // half-open
}

Parse_Diagnostic_Key :: struct {
    bytes:               [PARSE_DIAGNOSTIC_KEY_CAPACITY]u8,
    prefix_length:       u8,
    suffix_length:       u8,
    decoded_byte_length: int,
    omitted_byte_count:  int,
    source:              Source_Byte_Range,
    truncated:           bool,
}

Parse_Diagnostic_Path_Segment :: union #no_nil {
    Parse_Diagnostic_Key,
    Path_Index,
}

Parse_Diagnostic_Path :: struct {
    segments:              [PARSE_DIAGNOSTIC_PATH_CAPACITY]Parse_Diagnostic_Path_Segment,
    segment_count:         u8,
    prefix_count:          u8,
    total_segment_count:   u16,
    omitted_segment_count: u16,
    truncated:             bool,
}
```

The path denotes the deepest semantic destination established before failure: include fully decoded key components and the prospective index while parsing an array element, omit a key component that could not be decoded, include the complete attempted path subject to the declared bounds for a definition conflict, and use the empty path before any semantic location is known. It does not assert that the failed value was committed.

If the path has at most 32 segments, store all segments in order, set `prefix_count == segment_count`, and report no omission. Otherwise store the first eight followed by the final 24, set `segment_count == 32`, and record the exact total and omitted counts. The omitted run is logically between `segments[prefix_count-1]` and `segments[prefix_count]`.

A complete key of at most 64 decoded bytes occupies `bytes[:prefix_length]`, has `suffix_length == 0`, and is not truncated. For a longer key, store the longest valid UTF-8 prefix ending at or before byte 32, then the longest valid UTF-8 suffix beginning at or after `len(key)-32`; pack the suffix immediately after the prefix. Record both stored lengths, the original length, and their difference as the omitted count. This may store fewer than 64 bytes to avoid splitting a scalar.

A key's `source` covers its complete simple-key component, including opening and closing quotes when quoted but excluding surrounding whitespace and path dots. Components written in the failing expression use those current ranges. Prefix components inherited from the active table use the component ranges from the standard or AoT header that most recently selected that active table. Other traversed components use the current expression when present, otherwise the range that created that semantic entry. The copied bytes remain usable after input release; a caller that retained the input may use `source` to recover exact source spelling. Expose every segment/key truncation field and never present an excerpt as complete.

### Ownership, allocation failure, and cleanup

Use only the allocator selected by the public call for the document, decoded strings and keys, container storage, transient lookup/definition state, and other parse scratch. Never fall back to ambient `context.allocator`. Every allocation checks both returned storage and `Allocator_Error`, and every newly created owner is placed under cleanup responsibility before the next fallible step.

Parsing is transactional as established in issue 08. Success transfers one uniform-allocation `Document` owner and no scratch ownership. Any encoding, lexical, grammar, scalar, definition, depth, checked-size, or allocation error recursively destroys the entire partial semantic tree, cleans every unattached temporary value and all parser sidecars, and returns a zero `Document`. With arbitrary-order individually freeing allocators, release storage immediately; with externally reclaimed allocators, perform logical cleanup and leave physical reclamation to the allocator lifetime. Error values contain no allocation and need no destructor. The input can be changed or released immediately after either success or failure.

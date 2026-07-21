# Public interface freeze

Status: approved declaration blueprint

This file closes the declaration-level choices left conceptual by issues 06 and 08–12. Stage 0 transcribes this blueprint into compiling Odin declarations and may adjust only syntax required by the Reference Odin compiler. Names, alternatives, payload meaning, precedence, and lifetimes are frozen here. The exact parse diagnostic declarations in issue 09 are incorporated unchanged rather than duplicated.

## 1. Shared diagnostic declarations

The source and parse-path declarations are exactly those in issue 09:

- `Source_Position`, `Source_Range`, `Optional_Source_Range`, and `Source_Byte_Range`;
- `Path_Index`, `Path_Segment`, and `Path` from issue 07;
- `Parse_Diagnostic_Key`, `Parse_Diagnostic_Path_Segment`, and `Parse_Diagnostic_Path`;
- capacities 32 path segments, first 8/final 24 on truncation, and 64 key bytes with UTF-8-safe prefix/suffix truncation.

Common encode/typed paths use:

```odin
Encode_Diagnostic_Path_Segment :: union #no_nil {
    string,     // borrowed under issue 08's source-lifetime rules
    Path_Index, // copied
}

Encode_Diagnostic_Path :: struct {
    segments:              [32]Encode_Diagnostic_Path_Segment,
    segment_count:         u8,
    prefix_count:          u8,
    total_segment_count:   u16,
    omitted_segment_count: u16,
    truncated:             bool,
}
```

All errors are allocation-free ordinary unions whose nil state is success. Exact `runtime.Allocator_Error` and `io.Error` values are installed directly in their stated alternatives; `.None` is never installed.

## 2. Temporal procedures

The five transparent values and `temporal.Error` are exactly issue 06. The public procedure names are:

```odin
validate :: proc {
    validate_local_date,
    validate_local_time,
    validate_local_date_time,
    validate_utc_offset,
    validate_offset_date_time,
}

compare :: proc {
    compare_local_date,
    compare_local_time,
    compare_local_date_time,
}

compare_instant :: proc(a, b: Offset_Date_Time) -> (ordering: int, err: Error)

local_date_to_datetime   :: proc(value: Local_Date) -> (datetime.Date, Error)
local_date_from_datetime :: proc(value: datetime.Date) -> (Local_Date, Error)
local_time_to_datetime   :: proc(value: Local_Time) -> (datetime.Time, Error)
local_time_from_datetime :: proc(value: datetime.Time) -> (Local_Time, Error)
local_date_time_to_datetime   :: proc(value: Local_Date_Time) -> (datetime.DateTime, Error)
local_date_time_from_datetime :: proc(value: datetime.DateTime) -> (Local_Date_Time, Error)
offset_date_time_to_time :: proc(value: Offset_Date_Time) -> (time.Time, Error)
offset_date_time_from_time_utc :: proc(value: time.Time) -> (Offset_Date_Time, Error)
offset_date_time_from_time :: proc(value: time.Time, offset: UTC_Offset) -> (Offset_Date_Time, Error)
```

Every procedure validates operands before conversion/comparison. For binary operations, validate the left operand completely before the right. Within one value, validation order is date before time before offset, and component order follows field order. This fixes which `temporal.Error` wins when caller-constructed values violate multiple invariants.

`offset_date_time_from_time_utc` produces known zero UTC. `offset_date_time_from_time` shifts the displayed local components by the supplied validated fixed offset; unknown offset uses zero displacement and remains unknown. No conversion consults machine timezone state.

## 3. Parse errors

`Parse_Error` and every supporting declaration are exactly the exhaustive issue-09 declarations:

```text
Parse_Configuration_Error = Invalid_Allocator | Invalid_Max_Depth
Parse_Encoding_Error      = Invalid_UTF8
Parse_Lexical_Error       = Illegal_Character | Invalid_Newline |
                            Invalid_Comment_Character | Unterminated_Basic_String |
                            Unterminated_Literal_String | Invalid_String_Character |
                            Invalid_Escape | Invalid_Unicode_Escape | Invalid_Bare_Key
Parse_Value_Error_Kind    = Invalid_Integer | Integer_Out_Of_Range |
                            Invalid_Float | Float_Out_Of_Range | Invalid_Boolean |
                            Invalid_Temporal | Invalid_Value
Parse_Definition_Error_Kind = Duplicate_Key | Non_Table_Path_Component |
                              Table_Redefined | Dotted_Table_Redefined |
                              Inline_Table_Extended | Table_Array_Conflict |
                              Array_Of_Tables_Conflict
Parse_Limit_Error         = Maximum_Depth_Exceeded | Size_Overflow
```

`Parse_Syntax`, `Parse_Syntax_Set`, `Parse_Grammar_Error`, `Parse_Definition_Form`, `Parse_Definition_Error`, `Parse_Value_Error`, `Parse_Diagnostic_Detail`, `Parse_Diagnostic`, and `Parse_Error` retain the exact fields from issue 09.

## 4. Clone errors

```odin
Clone_Configuration_Error :: enum u8 {
    Invalid_Allocator,
}

Clone_Data_Error_Kind :: enum u8 {
    Invalid_Document,
    Invalid_Value_State,
    Invalid_Container,
    Invalid_Text,
    Duplicate_Key,
    Invalid_Temporal,
    Cycle,
    Ownership_Alias,
    Allocator_Mismatch,
}

Clone_Limit_Error :: enum u8 {
    Maximum_Depth_Exceeded,
    Size_Overflow,
}

Clone_Diagnostic_Detail :: union #no_nil {
    Clone_Data_Error_Kind,
    Clone_Limit_Error,
}

Clone_Diagnostic :: struct {
    detail:         Clone_Diagnostic_Detail,
    temporal_error: temporal.Error, // non-.None only with Invalid_Temporal
    path:           Encode_Diagnostic_Path,
}

Clone_Error :: union {
    Clone_Configuration_Error,
    Clone_Diagnostic,
    runtime.Allocator_Error,
}
```

`clone_document` uses `.Invalid_Document` for nil, zero, or uninitialized input. `clone_value` uses `.Invalid_Value_State` for an invalid union. A standalone valid zero-value `Value` remains the empty string.

## 5. Mutation errors

```odin
Mutation_Data_Error_Kind :: enum u8 {
    Invalid_Table,
    Invalid_Value_State,
    Invalid_Key_Text,
    Invalid_Value_Text,
    Duplicate_Key,
    Invalid_Temporal,
    Cycle,
    Ownership_Alias,
    Allocator_Mismatch,
}

Mutation_Limit_Error :: enum u8 {
    Maximum_Depth_Exceeded,
    Size_Overflow,
}

Mutation_Diagnostic_Detail :: union #no_nil {
    Mutation_Data_Error_Kind,
    Mutation_Limit_Error,
}

Mutation_Diagnostic :: struct {
    detail:         Mutation_Diagnostic_Detail,
    temporal_error: temporal.Error,
    path:           Encode_Diagnostic_Path,
}

Mutation_Error :: union {
    Mutation_Diagnostic,
    runtime.Allocator_Error,
}
```

`.Duplicate_Key` is reachable only when the caller-supplied value already contains a malformed table; direct `set` itself replaces or appends and never creates a duplicate. `.Allocator_Mismatch` includes an uninitialized/nil retained table allocator. The path is local to the target table for the reason fixed in issue 14.

## 6. Semantic unparse errors

```odin
Unparse_Configuration_Error :: enum u8 {
    Invalid_Allocator,
    Nil_Options,
    Invalid_Max_Depth,
}

Unparse_Data_Error_Kind :: enum u8 {
    Invalid_Document,
    Invalid_Value_State,
    Invalid_Container,
    Invalid_Text,
    Duplicate_Key,
    Invalid_Temporal,
    Cycle,
    Ownership_Alias,
    Allocator_Mismatch,
}

Unparse_Limit_Error :: enum u8 {
    Maximum_Depth_Exceeded,
    Size_Overflow,
}

Unparse_Diagnostic_Detail :: union #no_nil {
    Unparse_Data_Error_Kind,
    Unparse_Limit_Error,
}

Unparse_Diagnostic :: struct {
    detail:         Unparse_Diagnostic_Detail,
    temporal_error: temporal.Error,
    path:           Encode_Diagnostic_Path,
}

Unparse_Error :: union {
    Unparse_Configuration_Error,
    Unparse_Diagnostic,
    runtime.Allocator_Error,
    io.Error,
}
```

`Nil_Options` applies only to writer forms. Allocated forms cannot return `io.Error`. Semantic unparse ignores `Marshal_Options.codecs` without validating it.

## 7. Typed marshal errors

```odin
Marshal_Configuration_Error :: enum u8 {
    Invalid_Allocator,
    Nil_Options,
    Invalid_Max_Depth,
    Invalid_Codec_Registry,
}

Marshal_Data_Error_Kind :: enum u8 {
    Invalid_Root_Shape,
    Unsupported_Type,
    Unsupported_Nil,
    Invalid_Value_State,
    Invalid_Container,
    Invalid_Text,
    Duplicate_Key,
    Invalid_Temporal,
    Integer_Out_Of_Range,
    Float_Out_Of_Range,
    Malformed_Tag,
    Effective_Field_Name_Collision,
    Unsupported_Map_Key_Type,
    Converted_Map_Key_Collision,
    Active_Recursion_Cycle,
    Codec_Value_Cycle,
    Codec_Value_Ownership_Alias,
    Codec_Value_Allocator_Mismatch,
}

Marshal_Limit_Error :: enum u8 {
    Maximum_Depth_Exceeded,
    Size_Overflow,
}

Marshal_Data_Error :: struct {
    kind:              Marshal_Data_Error_Kind,
    source_type:       typeid,
    related_type:      typeid,
    temporal_error:    temporal.Error,
    expected_count:    int,
    actual_count:      int,
}

Marshal_Codec_Error :: struct {
    registered_type: typeid,
    code:            u32,
}

Marshal_Diagnostic_Detail :: union #no_nil {
    Marshal_Data_Error,
    Marshal_Limit_Error,
    Marshal_Codec_Error,
}

Marshal_Diagnostic :: struct {
    detail: Marshal_Diagnostic_Detail,
    path:   Encode_Diagnostic_Path,
}

Marshal_Error :: union {
    Marshal_Configuration_Error,
    Marshal_Diagnostic,
    runtime.Allocator_Error,
    io.Error,
}
```

Unused payload fields are zero. A callback allocator failure is the outer exact allocator alternative, never `Marshal_Codec_Error`. Invalid callback-produced semantic values use the corresponding codec-value or common data kind at the current path. Allocated forms cannot return `io.Error`; writer forms use the exact count/error behavior in issue 10.

## 8. Typed unmarshal errors

```odin
Unmarshal_Configuration_Error :: enum u8 {
    Invalid_Allocator,
    Invalid_Max_Depth,
    Nil_Destination,
    Invalid_Codec_Registry,
}

Unmarshal_Data_Error_Kind :: enum u8 {
    Invalid_Root_Shape,
    Unsupported_Destination_Type,
    Source_Destination_Kind_Mismatch,
    Integer_Out_Of_Range,
    Float_Out_Of_Range,
    Fixed_Array_Length_Mismatch,
    Malformed_Tag,
    Effective_Field_Name_Collision,
    Unknown_Field,
    Nonzero_Destination_Ownership,
    Destination_Size_Overflow,
    Maximum_Depth_Exceeded,
}

Unmarshal_Data_Error :: struct {
    kind:             Unmarshal_Data_Error_Kind,
    destination_type: typeid,
    source_kind:      Value_Kind,
    related_type:     typeid,
    expected_count:   int,
    actual_count:     int,
}

Unmarshal_Codec_Error :: struct {
    registered_type: typeid,
    code:            u32,
}

Unmarshal_Diagnostic_Detail :: union #no_nil {
    Unmarshal_Data_Error,
    Unmarshal_Codec_Error,
}

Unmarshal_Diagnostic :: struct {
    detail: Unmarshal_Diagnostic_Detail,
    source: Optional_Source_Range,
    path:   Encode_Diagnostic_Path,
}

Unmarshal_Parse_Error :: struct {
    error: Parse_Error,
}

Unmarshal_Error :: union {
    Unmarshal_Configuration_Error,
    Unmarshal_Parse_Error,
    Unmarshal_Diagnostic,
    runtime.Allocator_Error,
}
```

`Value_Kind` is a public enum mirroring the ten `Value` alternatives solely for allocation-free diagnostics:

```odin
Value_Kind :: enum u8 {
    String, Integer, Float, Boolean,
    Offset_Date_Time, Local_Date_Time, Local_Date, Local_Time,
    Array, Table,
}
```

A custom callback allocator failure is the outer exact allocator alternative. A codec-defined failure uses `Unmarshal_Codec_Error` and the source range of the bound semantic value. The callback's current slot is zero on failure.

## 9. Codec registry declarations and errors

The callback and registry procedure signatures are exactly those in sections 4 and 12 of the design specification. The concrete public registry representation is transparent only for lifecycle state, not lookup internals:

```odin
Codec_Registry :: struct {
    marshalers:   map[typeid]Codec_Marshaler,
    unmarshalers: map[typeid]Codec_Unmarshaler,
    allocator:    mem.Allocator,
    initialized:  bool,
}

Codec_Registry_Data_Error :: enum u8 {
    Invalid_Allocator,
    Invalid_Registry,
    Invalid_Type_ID,
    Nil_Callback,
    Duplicate_Codec,
}

Codec_Registry_Error :: union {
    Codec_Registry_Data_Error,
    runtime.Allocator_Error,
}
```

The maps are interface-visible because Odin has no private fields, but callers must treat them as implementation-owned state. Direct mutation violates the registry contract. A future opaque representation is a pre-1.0 breaking change or post-1.0 major change.

## 10. Public procedure attributes and defaults

Apply `@(require_results)` to every public procedure returning an error, `bool` indicating lookup/removal, or an owned result. Cleanup procedures remain result-less and do not use the attribute.

The exact procedure families and defaults are those in design-spec sections 4 and 12:

- `parse::{parse_bytes, parse_string}`;
- `unparse`, `unparse_to_writer`;
- `marshal`, `marshal_to_writer`;
- `unmarshal`, `unmarshal_string`;
- `clone_document`, `destroy_document`, `clone_value`, `destroy_value`;
- `get`, `set`, `remove`;
- registry init/destroy and directional registration.

Allocator defaults are `context.allocator`; caller location defaults are `#caller_location`; allocating/non-writer options are values defaulting to `{}`; writer options are non-nil stable pointers. `Parse_Options`, `Marshal_Options`, and `Unmarshal_Options` have exactly the fields in design-spec section 4 and no private working state.

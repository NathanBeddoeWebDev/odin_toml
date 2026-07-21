package toml

import "base:runtime"
import "core:io"
import temporal "temporal"

Source_Position :: struct {
	byte:   int,
	line:   int,
	column: int,
}

Source_Range :: struct {
	start: Source_Position,
	end:   Source_Position,
}

Optional_Source_Range :: struct {
	value: Source_Range,
	ok:    bool,
}

Source_Byte_Range :: struct {
	start: int,
	end:   int,
}

PARSE_DIAGNOSTIC_PATH_CAPACITY     :: 32
PARSE_DIAGNOSTIC_PATH_PREFIX_COUNT :: 8
PARSE_DIAGNOSTIC_KEY_CAPACITY      :: 64
PARSE_DIAGNOSTIC_KEY_PREFIX_BYTES  :: 32

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

Encode_Diagnostic_Path_Segment :: union #no_nil {
	string,
	Path_Index,
}

Encode_Diagnostic_Path :: struct {
	segments:              [32]Encode_Diagnostic_Path_Segment,
	segment_count:         u8,
	prefix_count:          u8,
	total_segment_count:   u16,
	omitted_segment_count: u16,
	truncated:             bool,
}

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
	temporal_error: temporal.Error,
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
	temporal_error: temporal.Error,
	path:           Encode_Diagnostic_Path,
}

Clone_Error :: union {
	Clone_Configuration_Error,
	Clone_Diagnostic,
	runtime.Allocator_Error,
}

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
	kind:           Marshal_Data_Error_Kind,
	source_type:    typeid,
	related_type:   typeid,
	temporal_error: temporal.Error,
	expected_count: int,
	actual_count:   int,
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

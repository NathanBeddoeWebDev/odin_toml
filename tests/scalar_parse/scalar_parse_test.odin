package scalar_parse_test

import "base:runtime"
import "core:math"
import "core:mem"
import "core:testing"
import toml "../.."
import temporal "../../vendor/temporal"
import test_support "../support"

value_for :: proc(t: ^testing.T, doc: ^toml.Document, key: string) -> ^toml.Value {
	value, ok := toml.get(&doc.root, key)
	testing.expect(t, ok)
	return value
}

document_is_zero :: proc(doc: toml.Document) -> bool {
	return raw_data(doc.root) == nil && len(doc.root) == 0 && cap(doc.root) == 0 &&
	       doc.root.allocator.procedure == nil && doc.allocator.procedure == nil
}

mutable_bytes :: proc(text: string) -> []byte {
	bytes, err := make([]byte, len(text))
	assert(err == nil)
	copy(bytes, transmute([]byte)text)
	return bytes
}

@(test)
test_scalar_assignments_decode_owned_semantic_values :: proc(t: ^testing.T) {
	input := `bare = "value"
"escaped\u002Ekey" = 'literal'
integer = -9223372036854775808
float = 1.0000000000000002
truth = true
falsehood = false
`
	doc, err := toml.parse_string(input)
	testing.expect(t, err == nil)
	if err != nil {
		return
	}
	defer toml.destroy_document(&doc)
	testing.expect_value(t, len(doc.root), 6)

	text, text_ok := value_for(t, &doc, "bare").(toml.String)
	testing.expect(t, text_ok)
	testing.expect_value(t, text, "value")
	escaped, escaped_ok := value_for(t, &doc, "escaped.key").(toml.String)
	testing.expect(t, escaped_ok)
	testing.expect_value(t, escaped, "literal")
	integer, integer_ok := value_for(t, &doc, "integer").(toml.Integer)
	testing.expect(t, integer_ok)
	testing.expect_value(t, integer, toml.Integer(min(i64)))
	float, float_ok := value_for(t, &doc, "float").(toml.Float)
	testing.expect(t, float_ok)
	testing.expect_value(t, transmute(u64)float, u64(0x3ff0_0000_0000_0001))
	truth, truth_ok := value_for(t, &doc, "truth").(toml.Boolean)
	testing.expect(t, truth_ok)
	testing.expect(t, truth)
	falsehood, falsehood_ok := value_for(t, &doc, "falsehood").(toml.Boolean)
	testing.expect(t, falsehood_ok)
	testing.expect(t, !falsehood)
}

parse_diagnostic_from :: proc(err: toml.Parse_Error) -> (toml.Parse_Diagnostic, bool) {
	return err.(toml.Parse_Diagnostic)
}

expect_parse_path_metadata :: proc(t: ^testing.T, path: toml.Parse_Diagnostic_Path) {
	if path.total_segment_count <= 32 {
		testing.expect_value(t, path.segment_count, u8(path.total_segment_count))
		testing.expect_value(t, path.prefix_count, u8(path.total_segment_count))
		testing.expect_value(t, path.omitted_segment_count, u16(0))
		testing.expect(t, !path.truncated)
	} else {
		testing.expect_value(t, path.segment_count, u8(32))
		testing.expect_value(t, path.prefix_count, u8(8))
		testing.expect_value(t, path.omitted_segment_count, path.total_segment_count-32)
		testing.expect(t, path.truncated)
	}
}

expect_valid_through_both_overloads :: proc(t: ^testing.T, input: string) {
	string_doc, string_error := toml.parse_string(input)
	testing.expect(t, string_error == nil)
	if string_error == nil {
		toml.destroy_document(&string_doc)
	}
	byte_doc, byte_error := toml.parse_bytes(transmute([]byte)input)
	testing.expect(t, byte_error == nil)
	if byte_error == nil {
		toml.destroy_document(&byte_doc)
	}
}

expect_rejected_through_both_overloads :: proc(t: ^testing.T, input: string) {
	string_doc, string_error := toml.parse_string(input)
	testing.expect(t, string_error != nil)
	testing.expect(t, document_is_zero(string_doc))
	byte_doc, byte_error := toml.parse_bytes(transmute([]byte)input)
	testing.expect(t, byte_error != nil)
	testing.expect(t, document_is_zero(byte_doc))
}

@(test)
test_all_string_forms_apply_exact_escape_and_newline_rules :: proc(t: ^testing.T) {
	input := `basic = "quote: \" slash: \\ controls: \b\t\n\f\r\e\x00 unicode: \u03B1 \U0001FABA"
literal = 'C:\Users\name'
multiline = """
first \
    second
third"""
multiline_literal = '''
alpha
beta'''
quotes = """one " two "" three"""
apostrophes = '''one ' two '' three'''
`
	doc, err := toml.parse_string(input)
	testing.expect(t, err == nil)
	if err != nil {
		return
	}
	defer toml.destroy_document(&doc)

	basic, basic_ok := value_for(t, &doc, "basic").(toml.String)
	testing.expect(t, basic_ok)
	testing.expect_value(
		t,
		basic,
		"quote: \" slash: \\ controls: \b\t\n\f\r\x1b\x00 unicode: α 🪺",
	)
	literal, literal_ok := value_for(t, &doc, "literal").(toml.String)
	testing.expect(t, literal_ok)
	testing.expect_value(t, literal, `C:\Users\name`)
	multiline, multiline_ok := value_for(t, &doc, "multiline").(toml.String)
	testing.expect(t, multiline_ok)
	when ODIN_OS == .Windows {
		testing.expect_value(t, multiline, "first second\r\nthird")
	} else {
		testing.expect_value(t, multiline, "first second\nthird")
	}
	multiline_literal, multiline_literal_ok := value_for(t, &doc, "multiline_literal").(toml.String)
	testing.expect(t, multiline_literal_ok)
	when ODIN_OS == .Windows {
		testing.expect_value(t, multiline_literal, "alpha\r\nbeta")
	} else {
		testing.expect_value(t, multiline_literal, "alpha\nbeta")
	}
	quotes, quotes_ok := value_for(t, &doc, "quotes").(toml.String)
	testing.expect(t, quotes_ok)
	testing.expect_value(t, quotes, `one " two "" three`)
	apostrophes, apostrophes_ok := value_for(t, &doc, "apostrophes").(toml.String)
	testing.expect(t, apostrophes_ok)
	testing.expect_value(t, apostrophes, "one ' two '' three")
}

@(test)
test_strings_and_keys_never_borrow_input :: proc(t: ^testing.T) {
	bytes := mutable_bytes(`"owned.key" = "owned value"`)
	defer delete(bytes)
	doc, err := toml.parse_bytes(bytes)
	testing.expect(t, err == nil)
	if err != nil {
		return
	}
	defer toml.destroy_document(&doc)
	for &byte in bytes {
		byte = 'x'
	}
	testing.expect_value(t, doc.root[0].key, "owned.key")
	text, text_ok := doc.root[0].value.(toml.String)
	testing.expect(t, text_ok)
	testing.expect_value(t, text, "owned value")
}

@(test)
test_integer_float_and_boolean_boundaries :: proc(t: ^testing.T) {
	input := `max = 9223372036854775807
min = -9223372036854775808
hex = 0x7fff_ffff_ffff_ffff
octal = 0o7_777
binary = 0b1010_0101
plus_zero = +0
negative_zero = -0.0
subnormal = 4.9406564584124654e-324
underflow = -1e-4000
positive_inf = +inf
negative_inf = -inf
not_number = -nan
`
	doc, err := toml.parse_string(input)
	testing.expect(t, err == nil)
	if err != nil {
		return
	}
	defer toml.destroy_document(&doc)

	max_value, max_value_ok := value_for(t, &doc, "max").(toml.Integer)
	testing.expect(t, max_value_ok)
	testing.expect_value(t, max_value, toml.Integer(max(i64)))
	min_value, min_value_ok := value_for(t, &doc, "min").(toml.Integer)
	testing.expect(t, min_value_ok)
	testing.expect_value(t, min_value, toml.Integer(min(i64)))
	hex, hex_ok := value_for(t, &doc, "hex").(toml.Integer)
	testing.expect(t, hex_ok)
	testing.expect_value(t, hex, toml.Integer(max(i64)))
	octal, octal_ok := value_for(t, &doc, "octal").(toml.Integer)
	testing.expect(t, octal_ok)
	testing.expect_value(t, octal, toml.Integer(4095))
	binary, binary_ok := value_for(t, &doc, "binary").(toml.Integer)
	testing.expect(t, binary_ok)
	testing.expect_value(t, binary, toml.Integer(0xa5))
	negative_zero, negative_zero_ok := value_for(t, &doc, "negative_zero").(toml.Float)
	testing.expect(t, negative_zero_ok)
	testing.expect_value(t, transmute(u64)negative_zero, u64(0x8000_0000_0000_0000))
	subnormal, subnormal_ok := value_for(t, &doc, "subnormal").(toml.Float)
	testing.expect(t, subnormal_ok)
	testing.expect_value(t, transmute(u64)subnormal, u64(1))
	underflow, underflow_ok := value_for(t, &doc, "underflow").(toml.Float)
	testing.expect(t, underflow_ok)
	testing.expect_value(t, transmute(u64)underflow, u64(0x8000_0000_0000_0000))
	positive_inf, positive_inf_ok := value_for(t, &doc, "positive_inf").(toml.Float)
	testing.expect(t, positive_inf_ok)
	testing.expect(t, math.is_inf(f64(positive_inf), 1))
	negative_inf, negative_inf_ok := value_for(t, &doc, "negative_inf").(toml.Float)
	testing.expect(t, negative_inf_ok)
	testing.expect(t, math.is_inf(f64(negative_inf), -1))
	not_number, not_number_ok := value_for(t, &doc, "not_number").(toml.Float)
	testing.expect(t, not_number_ok)
	testing.expect(t, math.is_nan(f64(not_number)))
	testing.expect_value(t, transmute(u64)not_number, u64(0x7ff8_0000_0000_0000))
}

@(test)
test_all_four_temporal_kinds_preserve_frozen_semantics :: proc(t: ^testing.T) {
	input := `offset = 1979-05-27T07:32:00.1234567899-00:00
utc = 1979-05-27t07:32z
local_datetime = 0000-02-29 23:59:60.9999999999
local_date = 9999-12-31
local_time = 07:32
`
	doc, err := toml.parse_string(input)
	testing.expect(t, err == nil)
	if err != nil {
		return
	}
	defer toml.destroy_document(&doc)

	offset, ok := value_for(t, &doc, "offset").(temporal.Offset_Date_Time)
	testing.expect(t, ok)
	testing.expect_value(t, offset.local, temporal.Local_Date_Time{
		date = {1979, 5, 27},
		time = {7, 32, 0, 123_456_789},
	})
	testing.expect_value(t, offset.offset, temporal.UTC_Offset{.Unknown, 0})
	utc, utc_ok := value_for(t, &doc, "utc").(temporal.Offset_Date_Time)
	testing.expect(t, utc_ok)
	testing.expect_value(t, utc.offset, temporal.UTC_Offset{.Known, 0})
	local_datetime, local_datetime_ok := value_for(t, &doc, "local_datetime").(temporal.Local_Date_Time)
	testing.expect(t, local_datetime_ok)
	testing.expect_value(t, local_datetime, temporal.Local_Date_Time{
		date = {0, 2, 29},
		time = {23, 59, 60, 999_999_999},
	})
	local_date, local_date_ok := value_for(t, &doc, "local_date").(temporal.Local_Date)
	testing.expect(t, local_date_ok)
	testing.expect_value(t, local_date, temporal.Local_Date{9999, 12, 31})
	local_time, local_time_ok := value_for(t, &doc, "local_time").(temporal.Local_Time)
	testing.expect(t, local_time_ok)
	testing.expect_value(t, local_time, temporal.Local_Time{7, 32, 0, 0})
}

@(test)
test_rejection_families_have_nearest_valid_neighbors_through_both_overloads :: proc(t: ^testing.T) {
	cases := [?]struct {
		valid:   string,
		invalid: string,
	}{
		// Encoding and every lexical detail have an adjacent valid spelling.
		{"a = \"é\"\n", "a = \"\xff\"\n"},
		{"a = 1\n", "\xef\xbb\xbfa = 1\n"},
		{"a = 1\r\n", "a = 1\r"},
		{"a = 1\n", "\xc2\xa0a = 1\n"},
		{"# good\n", "# bad\x01\n"},
		{"a = \"closed\"\n", `a = "unterminated`},
		{"a = 'closed'\n", "a = 'unterminated"},
		{"a = \"escaped \\n\"\n", "a = \"raw\x01\"\n"},
		{"a = \"\\n\"\n", "a = \"\\q\"\n"},
		{"a = \"\\uD7FF\"\n", "a = \"\\uD800\"\n"},
		{"a = 1\n", "? = 1\n"},
		// Grammar, value, definition, and unsupported-next-ticket forms.
		{"a = 1\n", "a 1\n"},
		{"a = 1\n", "a =\n"},
		{"a = 1\n", "a = 1 trailing\n"},
		{"a = true\n", "a = truex\n"},
		{"a = 0\n", "a = 01\n"},
		{"a = 1e+1\n", "a = 1e+\n"},
		{"a = 1979-02-28\n", "a = 1979-02-29\n"},
		{"a = 9223372036854775807\n", "a = 9223372036854775808\n"},
		{"a = 1.7976931348623157e308\n", "a = 1.7976931348623159e308\n"},
		{"a = 1\n", "a = value\n"},
		{"a = \"foo.bar\"\n", "a = foo.bar\n"},
		{"a = 1\nb = 2\n", "a = 1\na = 2\n"},
		{"a = [1]\n", "a = [1 2]\n"},
	}
	for test_case in cases {
		expect_valid_through_both_overloads(t, test_case.valid)
		expect_rejected_through_both_overloads(t, test_case.invalid)
	}
}

@(test)
test_scalar_candidate_classification_and_boundaries_are_frozen :: proc(t: ^testing.T) {
	cases := [?]struct {
		candidate:      string,
		kind:           toml.Parse_Value_Error_Kind,
		temporal_error: temporal.Error,
		error_start:    int,
		error_end:      int,
	}{
		{"truex", .Invalid_Boolean, .None, 4, 5},
		{"false_", .Invalid_Boolean, .None, 5, 6},
		{"1979-13-01", .Invalid_Temporal, .Invalid_Month, 0, 10},
		{"1979-02-29", .Invalid_Temporal, .Invalid_Day, 0, 10},
		{"25:00", .Invalid_Temporal, .Invalid_Hour, 0, 5},
		{"00:60", .Invalid_Temporal, .Invalid_Minute, 0, 5},
		{"00:00:61", .Invalid_Temporal, .Invalid_Second, 0, 8},
		{"1985-06-18T17:04:07+12:60", .Invalid_Temporal, .Invalid_Offset_Minutes, 0, 25},
		{"0xG", .Invalid_Integer, .None, 2, 3},
		{"+0x1", .Invalid_Integer, .None, 0, 1},
		{"01", .Invalid_Integer, .None, 1, 2},
		{"9223372036854775808", .Integer_Out_Of_Range, .None, 0, 19},
		{"-9223372036854775809", .Integer_Out_Of_Range, .None, 0, 20},
		{"1e+", .Invalid_Float, .None, 3, 3},
		{"infx", .Invalid_Float, .None, 3, 4},
		{"1.7976931348623159e308", .Float_Out_Of_Range, .None, 0, 22},
		{"truth", .Invalid_Value, .None, 0, 5},
		{"foo.bar", .Invalid_Value, .None, 0, 7},
	}
	for test_case in cases {
		buffer: [256]byte
		count := copy(buffer[:], "value = ")
		count += copy(buffer[count:], test_case.candidate)
		count += copy(buffer[count:], "\n")
		doc, err := toml.parse_bytes(buffer[:count])
		testing.expect(t, document_is_zero(doc))
		diagnostic, diagnostic_ok := parse_diagnostic_from(err)
		testing.expect(t, diagnostic_ok)
		value_error, value_error_ok := diagnostic.detail.(toml.Parse_Value_Error)
		testing.expect(t, value_error_ok)
		testing.expect_value(t, value_error.kind, test_case.kind)
		testing.expect_value(t, value_error.temporal_error, test_case.temporal_error)
		testing.expect_value(t, diagnostic.primary.start.byte, 8+test_case.error_start)
		testing.expect_value(t, diagnostic.primary.end.byte, 8+test_case.error_end)
		testing.expect_value(t, diagnostic.path.segment_count, u8(1))
		testing.expect_value(t, diagnostic.related, toml.Optional_Source_Range{})
		expect_parse_path_metadata(t, diagnostic.path)
	}
}

@(test)
test_lexical_and_grammar_diagnostics_remain_distinct :: proc(t: ^testing.T) {
	lexical_cases := [?]struct {
		input: string,
		kind:  toml.Parse_Lexical_Error,
	}{
		{"value = 1\r", .Invalid_Newline},
		{"# bad\x01\n", .Invalid_Comment_Character},
		{"value = \"raw\x01\"\n", .Invalid_String_Character},
		{"value = \"\\q\"\n", .Invalid_Escape},
		{"value = \"\\uD800\"\n", .Invalid_Unicode_Escape},
		{"value = \"unterminated", .Unterminated_Basic_String},
		{"value = 'unterminated", .Unterminated_Literal_String},
		{"é = 1\n", .Illegal_Character},
		{"? = 1\n", .Invalid_Bare_Key},
	}
	for test_case in lexical_cases {
		doc, err := toml.parse_string(test_case.input)
		testing.expect(t, document_is_zero(doc))
		diagnostic, diagnostic_ok := parse_diagnostic_from(err)
		testing.expect(t, diagnostic_ok)
		lexical, lexical_ok := diagnostic.detail.(toml.Parse_Lexical_Error)
		testing.expect(t, lexical_ok)
		testing.expect_value(t, lexical, test_case.kind)
		testing.expect_value(t, diagnostic.related, toml.Optional_Source_Range{})
		expect_parse_path_metadata(t, diagnostic.path)
	}

	grammar_cases := [?]struct {
		input:       string,
		expected:    toml.Parse_Syntax,
		found:       toml.Parse_Syntax,
		range_start: int,
		range_end:   int,
	}{
		{"value 1\n", .Equals, .Other, 6, 6},
		{"value\n", .Equals, .End_Of_Line, 5, 5},
		{"value =\n", .Value, .End_Of_Line, 7, 8},
		{"value = 1 trailing\n", .Expression_End, .Other, 10, 11},
	}
	for test_case in grammar_cases {
		doc, err := toml.parse_string(test_case.input)
		testing.expect(t, document_is_zero(doc))
		diagnostic, diagnostic_ok := parse_diagnostic_from(err)
		testing.expect(t, diagnostic_ok)
		grammar, grammar_ok := diagnostic.detail.(toml.Parse_Grammar_Error)
		testing.expect(t, grammar_ok)
		testing.expect(t, test_case.expected in grammar.expected)
		testing.expect_value(t, grammar.found, test_case.found)
		testing.expect_value(t, diagnostic.primary.start.byte, test_case.range_start)
		testing.expect_value(t, diagnostic.primary.end.byte, test_case.range_end)
		testing.expect_value(t, diagnostic.related, toml.Optional_Source_Range{})
		expect_parse_path_metadata(t, diagnostic.path)
	}

	unicode_space_doc, unicode_space_error := toml.parse_string("value = 1 \xc2\xa0\n")
	testing.expect(t, document_is_zero(unicode_space_doc))
	unicode_space_diagnostic, diagnostic_ok := parse_diagnostic_from(unicode_space_error)
	testing.expect(t, diagnostic_ok)
	unicode_space_lexical, lexical_ok := unicode_space_diagnostic.detail.(toml.Parse_Lexical_Error)
	testing.expect(t, lexical_ok)
	testing.expect_value(t, unicode_space_lexical, toml.Parse_Lexical_Error.Illegal_Character)
}

@(test)
test_root_comment_diagnostic_does_not_reuse_previous_key_path :: proc(t: ^testing.T) {
	doc, err := toml.parse_string("value = 1\n# bad\x01\n")
	testing.expect(t, document_is_zero(doc))
	diagnostic, diagnostic_ok := parse_diagnostic_from(err)
	testing.expect(t, diagnostic_ok)
	lexical, lexical_ok := diagnostic.detail.(toml.Parse_Lexical_Error)
	testing.expect(t, lexical_ok)
	testing.expect_value(t, lexical, toml.Parse_Lexical_Error.Invalid_Comment_Character)
	testing.expect_value(t, diagnostic.path, toml.Parse_Diagnostic_Path{})
}

@(test)
test_lazy_diagnostic_path_decodes_escaped_and_unicode_keys :: proc(t: ^testing.T) {
	input := `"\u03B1".'β'.leaf = nope
`
	doc, err := toml.parse_string(input)
	testing.expect(t, document_is_zero(doc))
	diagnostic, diagnostic_ok := parse_diagnostic_from(err)
	testing.expect(t, diagnostic_ok)
	value_error, value_error_ok := diagnostic.detail.(toml.Parse_Value_Error)
	testing.expect(t, value_error_ok)
	testing.expect_value(t, value_error.kind, toml.Parse_Value_Error_Kind.Invalid_Value)
	testing.expect_value(t, diagnostic.path.segment_count, u8(3))
	expected_text := [?]string{"α", "β", "leaf"}
	expected_source := [?]toml.Source_Byte_Range{{0, 8}, {9, 13}, {14, 18}}
	for index in 0..<len(expected_text) {
		key, key_ok := diagnostic.path.segments[index].(toml.Parse_Diagnostic_Key)
		testing.expect(t, key_ok)
		testing.expect_value(t, string(key.bytes[:key.prefix_length]), expected_text[index])
		testing.expect_value(t, key.decoded_byte_length, len(expected_text[index]))
		testing.expect_value(t, key.source, expected_source[index])
	}
}

@(test)
test_ordinary_diagnostic_coordinates_count_unicode_scalars_tabs_and_crlf :: proc(t: ^testing.T) {
	input := "ok = 1\r\n\"é\"\t 1\n"
	doc, err := toml.parse_string(input)
	testing.expect(t, document_is_zero(doc))
	diagnostic, ok := parse_diagnostic_from(err)
	testing.expect(t, ok)
	grammar, grammar_ok := diagnostic.detail.(toml.Parse_Grammar_Error)
	testing.expect(t, grammar_ok)
	testing.expect(t, toml.Parse_Syntax.Equals in grammar.expected)
	testing.expect_value(t, grammar.found, toml.Parse_Syntax.Other)
	testing.expect_value(t, diagnostic.primary.start, toml.Source_Position{14, 2, 6})
	testing.expect_value(t, diagnostic.primary.end, toml.Source_Position{14, 2, 6})

	eof_doc, eof_error := toml.parse_string("\"é\"")
	testing.expect(t, document_is_zero(eof_doc))
	eof_diagnostic, eof_ok := parse_diagnostic_from(eof_error)
	testing.expect(t, eof_ok)
	testing.expect_value(t, eof_diagnostic.primary.start, toml.Source_Position{4, 1, 4})
	testing.expect_value(t, eof_diagnostic.primary.end, toml.Source_Position{4, 1, 4})
}

@(test)
test_whole_input_utf8_preflight_and_coordinates_are_exact :: proc(t: ^testing.T) {
	bytes := []byte{0x22, 0xc3, 0xa9, 0x22, ' ', '=', ' ', '1', '\n', 0xff}
	doc, err := toml.parse_bytes(bytes)
	testing.expect(t, document_is_zero(doc))
	diagnostic, ok := parse_diagnostic_from(err)
	testing.expect(t, ok)
	encoding, encoding_ok := diagnostic.detail.(toml.Parse_Encoding_Error)
	testing.expect(t, encoding_ok)
	testing.expect_value(t, encoding, toml.Parse_Encoding_Error.Invalid_UTF8)
	testing.expect_value(t, diagnostic.primary.start, toml.Source_Position{9, 2, 1})
	testing.expect_value(t, diagnostic.primary.end, toml.Source_Position{10, 2, 1})
	testing.expect_value(t, diagnostic.related, toml.Optional_Source_Range{})
	testing.expect_value(t, diagnostic.path, toml.Parse_Diagnostic_Path{})

	malformed := [?][]byte{
		{0x80}, {0xc0, 0x80}, {0xe0, 0x80, 0x80}, {0xed, 0xa0, 0x80},
		{0xf4, 0x90, 0x80, 0x80}, {0xe2, 0x82}, {0xe2, 'x', 0xa1},
	}
	for input in malformed {
		failed_doc, failed_error := toml.parse_bytes(input)
		testing.expect(t, document_is_zero(failed_doc))
		failed_diagnostic, diagnostic_ok := parse_diagnostic_from(failed_error)
		testing.expect(t, diagnostic_ok)
		testing.expect_value(t, failed_diagnostic.primary.start.byte, 0)
		testing.expect_value(t, failed_diagnostic.primary.end.byte, 1)
		testing.expect_value(t, failed_diagnostic.primary.start.line, 1)
		testing.expect_value(t, failed_diagnostic.primary.start.column, 1)
		testing.expect_value(t, failed_diagnostic.primary.end.line, 1)
		testing.expect_value(t, failed_diagnostic.primary.end.column, 1)
	}
}

@(test)
test_duplicate_decoded_key_reports_stable_path_and_related_range :: proc(t: ^testing.T) {
	input := mutable_bytes("bare = 1\n\"b\\u0061re\" = 2\n")
	defer delete(input)
	doc, err := toml.parse_bytes(input)
	testing.expect(t, document_is_zero(doc))
	for &byte in input {
		byte = 0
	}
	diagnostic, ok := parse_diagnostic_from(err)
	testing.expect(t, ok)
	definition, definition_ok := diagnostic.detail.(toml.Parse_Definition_Error)
	testing.expect(t, definition_ok)
	testing.expect_value(t, definition.kind, toml.Parse_Definition_Error_Kind.Duplicate_Key)
	testing.expect_value(t, definition.existing, toml.Parse_Definition_Form.Key_Value)
	testing.expect_value(t, definition.attempted, toml.Parse_Definition_Form.Key_Value)
	testing.expect(t, diagnostic.related.ok)
	testing.expect_value(t, diagnostic.related.value.start.byte, 0)
	testing.expect_value(t, diagnostic.related.value.end.byte, 8)
	testing.expect_value(t, diagnostic.primary.start.byte, 9)
	testing.expect_value(t, diagnostic.primary.end.byte, 20)
	testing.expect_value(t, diagnostic.path.segment_count, u8(1))
	segment, segment_ok := diagnostic.path.segments[0].(toml.Parse_Diagnostic_Key)
	testing.expect(t, segment_ok)
	testing.expect_value(t, string(segment.bytes[:segment.prefix_length]), "bare")
	testing.expect_value(t, segment.decoded_byte_length, 4)
	testing.expect(t, !segment.truncated)
	testing.expect_value(t, segment.source, toml.Source_Byte_Range{9, 20})
}

@(test)
test_long_diagnostic_keys_are_utf8_safe_bounded_snapshots :: proc(t: ^testing.T) {
	input := `"abcdefghijklmnopqrstuvwxyzαβγδεζηθικλmnopqrstuvwxyz0123456789" = 1
"abcdefghijklmnopqrstuvwxyzαβγδεζηθικλmnopqrstuvwxyz0123456789" = 2
`
	doc, err := toml.parse_string(input)
	testing.expect(t, document_is_zero(doc))
	diagnostic, ok := parse_diagnostic_from(err)
	testing.expect(t, ok)
	segment, segment_ok := diagnostic.path.segments[0].(toml.Parse_Diagnostic_Key)
	testing.expect(t, segment_ok)
	testing.expect(t, segment.truncated)
	testing.expect(t, int(segment.prefix_length) <= 32)
	testing.expect(t, int(segment.suffix_length) <= 32)
	testing.expect_value(
		t,
		segment.omitted_byte_count,
		segment.decoded_byte_length-int(segment.prefix_length)-int(segment.suffix_length),
	)
	testing.expect_value(t, diagnostic.path.segment_count, u8(1))
	testing.expect_value(t, diagnostic.path.omitted_segment_count, u16(0))
}

@(test)
test_configuration_precedence_is_nil_allocator_then_options_then_utf8 :: proc(t: ^testing.T) {
	nil_allocator: mem.Allocator
	bad_bytes := []byte{0xff}
	doc, err := toml.parse_bytes(
		bad_bytes,
		{max_depth = -1},
		nil_allocator,
	)
	testing.expect(t, document_is_zero(doc))
	configuration, ok := err.(toml.Parse_Configuration_Error)
	testing.expect(t, ok)
	testing.expect_value(t, configuration, toml.Parse_Configuration_Error.Invalid_Allocator)

	doc, err = toml.parse_bytes(bad_bytes, {max_depth = 257})
	testing.expect(t, document_is_zero(doc))
	configuration, ok = err.(toml.Parse_Configuration_Error)
	testing.expect(t, ok)
	testing.expect_value(t, configuration, toml.Parse_Configuration_Error.Invalid_Max_Depth)

	string_doc, string_error := toml.parse_string(
		"\xff",
		{max_depth = -1},
		nil_allocator,
	)
	testing.expect(t, document_is_zero(string_doc))
	configuration, ok = string_error.(toml.Parse_Configuration_Error)
	testing.expect(t, ok)
	testing.expect_value(t, configuration, toml.Parse_Configuration_Error.Invalid_Allocator)

	string_doc, string_error = toml.parse_string("\xff", {max_depth = 257})
	testing.expect(t, document_is_zero(string_doc))
	configuration, ok = string_error.(toml.Parse_Configuration_Error)
	testing.expect(t, ok)
	testing.expect_value(t, configuration, toml.Parse_Configuration_Error.Invalid_Max_Depth)

	valid_doc, valid_error := toml.parse_string("a = 1\n", {max_depth = 1})
	testing.expect(t, valid_error == nil)
	toml.destroy_document(&valid_doc)
}

@(test)
test_parse_allocation_failure_is_transactional_at_every_ordinal :: proc(t: ^testing.T) {
	input := `"escaped\u002Ekey" = "owned \u03B1"
float = 1.00000000000000033306690738754696212708950042724609375
other = -9223372036854775808
`
	backing := context.allocator
	baseline_events: [512]test_support.Allocator_Event
	baseline_live: [128]test_support.Live_Allocation
	baseline: test_support.Observed_Allocator
	test_support.observed_allocator_init(&baseline, backing, baseline_events[:], baseline_live[:])
	baseline_allocator := test_support.observed_allocator(&baseline)
	baseline_doc, baseline_error := toml.parse_string(input, allocator = baseline_allocator)
	testing.expect(t, baseline_error == nil)
	allocation_count := baseline.allocation_request_count
	toml.destroy_document(&baseline_doc)
	testing.expect(t, allocation_count > 0)
	testing.expect_value(t, baseline.live_count, 0)

	for fail_at in 1..=allocation_count {
		events: [512]test_support.Allocator_Event
		live: [128]test_support.Live_Allocation
		state: test_support.Observed_Allocator
		test_support.observed_allocator_init(&state, backing, events[:], live[:])
		state.fail_at_allocation = fail_at
		selected := test_support.observed_allocator(&state)
		rejecting: test_support.Rejecting_Allocator
		context.allocator = test_support.rejecting_allocator(&rejecting)
		failed_doc, failed_error := toml.parse_string(input, allocator = selected)
		context.allocator = backing

		testing.expect(t, document_is_zero(failed_doc))
		allocator_error, ok := failed_error.(runtime.Allocator_Error)
		testing.expect(t, ok)
		testing.expect_value(t, allocator_error, runtime.Allocator_Error.Out_Of_Memory)
		testing.expect_value(t, state.live_count, 0)
		testing.expect_value(t, state.foreign_release_count, 0)
		testing.expect_value(t, rejecting.allocation_attempt_count, 0)
	}
	context.allocator = backing

	byte_events: [32]test_support.Allocator_Event
	byte_live: [16]test_support.Live_Allocation
	byte_state: test_support.Observed_Allocator
	test_support.observed_allocator_init(&byte_state, backing, byte_events[:], byte_live[:])
	byte_state.fail_at_allocation = 1
	byte_allocator := test_support.observed_allocator(&byte_state)
	byte_doc, byte_error := toml.parse_bytes(
		transmute([]byte)input,
		allocator = byte_allocator,
	)
	testing.expect(t, document_is_zero(byte_doc))
	byte_allocator_error, byte_allocator_error_ok := byte_error.(runtime.Allocator_Error)
	testing.expect(t, byte_allocator_error_ok)
	testing.expect_value(t, byte_allocator_error, runtime.Allocator_Error.Out_Of_Memory)
	testing.expect_value(t, byte_state.live_count, 0)
}

@(test)
test_external_lifetime_parse_owns_and_logically_destroys_tree :: proc(t: ^testing.T) {
	buffer: [256 * 1024]byte
	arena: mem.Arena
	mem.arena_init(&arena, buffer[:])
	external: test_support.External_Lifetime_Allocator
	test_support.external_lifetime_allocator_init(&external, mem.arena_allocator(&arena), true)
	allocator := test_support.external_lifetime_allocator(&external)
	doc, err := toml.parse_string(
		`key = "value"
float = 1.25
`,
		allocator = allocator,
	)
	testing.expect(t, err == nil)
	testing.expect(t, arena.offset > 0)
	toml.destroy_document(&doc)
	testing.expect(t, document_is_zero(doc))
	testing.expect_value(t, external.release_attempt_count, 0)
	testing.expect_value(t, external.free_all_count, 0)
	mem.arena_free_all(&arena)
}

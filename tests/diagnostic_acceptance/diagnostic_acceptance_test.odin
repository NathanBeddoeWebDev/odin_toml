package diagnostic_acceptance_test

import "base:runtime"
import "core:mem"
import "core:reflect"
import "core:testing"
import toml "../.."
import temporal "external:temporal"
import test_support "../support"

expect_zero_parse_related :: proc(t: ^testing.T, related: toml.Optional_Source_Range) {
	testing.expect_value(t, related, toml.Optional_Source_Range{})
}

expect_encode_path_shape :: proc(t: ^testing.T, path: toml.Encode_Diagnostic_Path) {
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

expect_parse_path_shape :: proc(t: ^testing.T, path: toml.Parse_Diagnostic_Path) {
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

@(test)
test_parse_grammar_syntax_matrix_is_structurally_exact :: proc(t: ^testing.T) {
	cases := [?]struct {
		input:    string,
		expected: toml.Parse_Syntax_Set,
		found:    toml.Parse_Syntax,
		start:    int,
		end:      int,
	}{
		{"[]\n", {.Key}, .Right_Bracket, 1, 2},
		{"a 1\n", {.Equals}, .Other, 2, 2},
		{"a =\n", {.Value}, .End_Of_Line, 3, 4},
		{"a=[1 2]\n", {.Comma, .Right_Bracket}, .Other, 5, 6},
		{"a={b=1 c=2}\n", {.Comma, .Right_Brace}, .Other, 7, 8},
		{"[a", {.Table_Header}, .End_Of_Input, 2, 2},
		{"[[a]", {.Array_Of_Tables_Header}, .End_Of_Input, 4, 4},
		{"a=1 trailing\n", {.Expression_End}, .Other, 4, 5},
		{"a=[1 =]\n", {.Comma, .Right_Bracket}, .Equals, 5, 6},
		{"a=[1 .]\n", {.Comma, .Right_Bracket}, .Dot, 5, 6},
		{"a=[,]\n", {.Value}, .Comma, 3, 4},
		{"a=[1 []\n", {.Comma, .Right_Bracket}, .Left_Bracket, 5, 6},
		{"a=[1 }]\n", {.Comma, .Right_Bracket}, .Right_Brace, 5, 6},
		{"a=[1 {]\n", {.Comma, .Right_Bracket}, .Left_Brace, 5, 6},
	}
	for test_case in cases {
		doc, err := toml.parse_string(test_case.input)
		testing.expect(t, raw_data(doc.root) == nil)
		diagnostic, diagnostic_ok := err.(toml.Parse_Diagnostic)
		testing.expect(t, diagnostic_ok)
		if !diagnostic_ok {continue}
		grammar, grammar_ok := diagnostic.detail.(toml.Parse_Grammar_Error)
		testing.expect(t, grammar_ok)
		if grammar_ok {
			testing.expect_value(t, grammar, toml.Parse_Grammar_Error{
				expected = test_case.expected,
				found = test_case.found,
			})
		}
		testing.expect_value(t, diagnostic.primary.start.byte, test_case.start)
		testing.expect_value(t, diagnostic.primary.end.byte, test_case.end)
		expect_zero_parse_related(t, diagnostic.related)
		expect_parse_path_shape(t, diagnostic.path)
	}
}

@(test)
test_parse_bare_cr_coordinate_is_exact_after_unicode_and_tab :: proc(t: ^testing.T) {
	doc, err := toml.parse_string("\"é\"\t= 1\r")
	testing.expect(t, raw_data(doc.root) == nil)
	diagnostic, ok := err.(toml.Parse_Diagnostic)
	testing.expect(t, ok)
	if !ok {return}
	lexical, lexical_ok := diagnostic.detail.(toml.Parse_Lexical_Error)
	testing.expect(t, lexical_ok)
	if lexical_ok {testing.expect_value(t, lexical, toml.Parse_Lexical_Error.Invalid_Newline)}
	testing.expect_value(t, diagnostic.primary, toml.Source_Range{
		start = {byte = 8, line = 1, column = 8},
		end = {byte = 9, line = 1, column = 9},
	})
	expect_zero_parse_related(t, diagnostic.related)
	expect_parse_path_shape(t, diagnostic.path)
}

@(test)
test_parse_deep_key_path_preserves_exact_first_and_last_snapshots :: proc(t: ^testing.T) {
	input := "k00.k01.k02.k03.k04.k05.k06.k07.k08.k09.k10.k11.k12.k13.k14.k15.k16.k17.k18.k19.k20.k21.k22.k23.k24.k25.k26.k27.k28.k29.k30.k31.k32 = 1\n"
	doc, err := toml.parse_string(input, {max_depth = 32})
	testing.expect(t, raw_data(doc.root) == nil)
	diagnostic, ok := err.(toml.Parse_Diagnostic)
	testing.expect(t, ok)
	if !ok {return}
	limit, limit_ok := diagnostic.detail.(toml.Parse_Limit_Error)
	testing.expect(t, limit_ok)
	if limit_ok {testing.expect_value(t, limit, toml.Parse_Limit_Error.Maximum_Depth_Exceeded)}
	expect_zero_parse_related(t, diagnostic.related)
	expect_parse_path_shape(t, diagnostic.path)
	testing.expect_value(t, diagnostic.path.total_segment_count, u16(33))
	testing.expect_value(t, diagnostic.path.omitted_segment_count, u16(1))
	for stored_index in 0..<32 {
		logical_index := stored_index
		if stored_index >= 8 {logical_index += 1}
		key, key_ok := diagnostic.path.segments[stored_index].(toml.Parse_Diagnostic_Key)
		testing.expect(t, key_ok)
		if !key_ok {continue}
		expected := input[logical_index*4:logical_index*4+3]
		testing.expect_value(t, string(key.bytes[:key.prefix_length]), expected)
		testing.expect_value(t, key.prefix_length, u8(3))
		testing.expect_value(t, key.suffix_length, u8(0))
		testing.expect_value(t, key.decoded_byte_length, 3)
		testing.expect_value(t, key.omitted_byte_count, 0)
		testing.expect_value(t, key.source, toml.Source_Byte_Range{
			start = logical_index*4,
			end = logical_index*4+3,
		})
		testing.expect(t, !key.truncated)
	}
}

@(test)
test_parse_snapshots_outlive_input_with_exact_utf8_safe_long_key :: proc(t: ^testing.T) {
	key := "abcdefghijklmnopqrstuvwxyzαβγδεζηθικλmnopqrstuvwxyz0123456789"
	line := "\"abcdefghijklmnopqrstuvwxyzαβγδεζηθικλmnopqrstuvwxyz0123456789\" = 1\n"
	input, make_error := make([]byte, len(line)*2)
	assert(make_error == nil)
	copy(input, transmute([]byte)line)
	copy(input[len(line):], transmute([]byte)line)
	doc, err := toml.parse_bytes(input)
	testing.expect(t, raw_data(doc.root) == nil)
	for &byte in input {byte = 0}
	delete(input)

	diagnostic, ok := err.(toml.Parse_Diagnostic)
	testing.expect(t, ok)
	if !ok {return}
	definition, definition_ok := diagnostic.detail.(toml.Parse_Definition_Error)
	testing.expect(t, definition_ok)
	if definition_ok {
		testing.expect_value(t, definition, toml.Parse_Definition_Error{
			kind = .Duplicate_Key,
			existing = .Key_Value,
			attempted = .Key_Value,
		})
	}
	testing.expect_value(t, diagnostic.primary.start.byte, len(line))
	testing.expect_value(t, diagnostic.primary.end.byte, len(line)+len(key)+2)
	testing.expect(t, diagnostic.related.ok)
	if diagnostic.related.ok {
		testing.expect_value(t, diagnostic.related.value.start.byte, 0)
		testing.expect_value(t, diagnostic.related.value.end.byte, len(line)-1)
	}
	testing.expect_value(t, diagnostic.path.segment_count, u8(1))
	testing.expect_value(t, diagnostic.path.prefix_count, u8(1))
	testing.expect_value(t, diagnostic.path.total_segment_count, u16(1))
	testing.expect_value(t, diagnostic.path.omitted_segment_count, u16(0))
	testing.expect(t, !diagnostic.path.truncated)
	segment, segment_ok := diagnostic.path.segments[0].(toml.Parse_Diagnostic_Key)
	testing.expect(t, segment_ok)
	if segment_ok {
		testing.expect_value(t, segment.prefix_length, u8(32))
		testing.expect_value(t, segment.suffix_length, u8(32))
		testing.expect_value(t, segment.decoded_byte_length, 72)
		testing.expect_value(t, segment.omitted_byte_count, 8)
		testing.expect_value(t, string(segment.bytes[:32]), "abcdefghijklmnopqrstuvwxyzαβγ")
		testing.expect_value(t, string(segment.bytes[32:64]), "θικλmnopqrstuvwxyz0123456789")
		testing.expect_value(
			t, segment.source,
			toml.Source_Byte_Range{len(line), len(line)+len(key)+2},
		)
		testing.expect(t, segment.truncated)
	}

	exact_key := "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789+-"
	exact_input := "\"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789+-\" = 1\n\"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789+-\" = 2\n"
	exact_doc, exact_error := toml.parse_string(exact_input)
	testing.expect(t, raw_data(exact_doc.root) == nil)
	exact_diagnostic, exact_ok := exact_error.(toml.Parse_Diagnostic)
	testing.expect(t, exact_ok)
	if exact_ok {
		exact_segment, exact_segment_ok := exact_diagnostic.path.segments[0].(toml.Parse_Diagnostic_Key)
		testing.expect(t, exact_segment_ok)
		if exact_segment_ok {
			testing.expect_value(t, len(exact_key), 64)
			testing.expect_value(t, exact_segment.prefix_length, u8(64))
			testing.expect_value(t, exact_segment.suffix_length, u8(0))
			testing.expect_value(t, exact_segment.decoded_byte_length, 64)
			testing.expect_value(t, exact_segment.omitted_byte_count, 0)
			testing.expect_value(t, string(exact_segment.bytes[:64]), exact_key)
			testing.expect(t, !exact_segment.truncated)
		}
	}
}

owned_string :: proc(text: string, allocator: mem.Allocator) -> string {
	if len(text) == 0 {return ""}
	bytes, err := make([]byte, len(text), allocator)
	assert(err == nil)
	copy(bytes, transmute([]byte)text)
	return string(bytes)
}

@(test)
test_clone_missing_data_alternatives_are_structurally_exact :: proc(t: ^testing.T) {
	zero: toml.Document
	cloned, err := toml.clone_document(&zero)
	testing.expect(t, raw_data(cloned.root) == nil)
	diagnostic, ok := err.(toml.Clone_Diagnostic)
	testing.expect(t, ok)
	if ok {
		kind, detail_ok := diagnostic.detail.(toml.Clone_Data_Error_Kind)
		testing.expect(t, detail_ok)
		if detail_ok {testing.expect_value(t, kind, toml.Clone_Data_Error_Kind.Invalid_Document)}
		testing.expect_value(t, diagnostic.temporal_error, temporal.Error.None)
		testing.expect_value(t, diagnostic.path, toml.Encode_Diagnostic_Path{})
	}

	invalid_union := toml.Value(toml.Integer(1))
	reflect.set_union_variant_raw_tag(invalid_union, 255)
	value_clone, value_error := toml.clone_value(&invalid_union)
	zero_text, zero_ok := value_clone.(toml.String)
	testing.expect(t, zero_ok)
	if zero_ok {testing.expect_value(t, zero_text, "")}
	diagnostic, ok = value_error.(toml.Clone_Diagnostic)
	testing.expect(t, ok)
	if ok {
		kind, detail_ok := diagnostic.detail.(toml.Clone_Data_Error_Kind)
		testing.expect(t, detail_ok)
		if detail_ok {testing.expect_value(t, kind, toml.Clone_Data_Error_Kind.Invalid_Value_State)}
		testing.expect_value(t, diagnostic.temporal_error, temporal.Error.None)
		testing.expect_value(t, diagnostic.path, toml.Encode_Diagnostic_Path{})
	}

	buffer: [4096]byte
	arena: mem.Arena
	mem.arena_init(&arena, buffer[:])
	allocator := mem.arena_allocator(&arena)
	table, table_error := make(toml.Table, 2, allocator)
	assert(table_error == nil)
	table[0] = {key = owned_string("same", allocator), value = toml.Value(toml.Integer(1))}
	table[1] = {key = owned_string("same", allocator), value = toml.Value(toml.Integer(2))}
	document := toml.Document{root = table, allocator = allocator}
	cloned, err = toml.clone_document(&document)
	testing.expect(t, raw_data(cloned.root) == nil)
	diagnostic, ok = err.(toml.Clone_Diagnostic)
	testing.expect(t, ok)
	if ok {
		kind, detail_ok := diagnostic.detail.(toml.Clone_Data_Error_Kind)
		testing.expect(t, detail_ok)
		if detail_ok {testing.expect_value(t, kind, toml.Clone_Data_Error_Kind.Duplicate_Key)}
		testing.expect_value(t, diagnostic.temporal_error, temporal.Error.None)
		testing.expect_value(t, diagnostic.path.total_segment_count, u16(1))
		name, name_ok := diagnostic.path.segments[0].(string)
		testing.expect(t, name_ok)
		if name_ok {testing.expect_value(t, name, "same")}
		expect_encode_path_shape(t, diagnostic.path)
	}

	table[1].key = owned_string("date", allocator)
	table[1].value = toml.Value(temporal.Local_Date{2024, 2, 30})
	cloned, err = toml.clone_document(&document)
	testing.expect(t, raw_data(cloned.root) == nil)
	diagnostic, ok = err.(toml.Clone_Diagnostic)
	testing.expect(t, ok)
	if ok {
		kind, detail_ok := diagnostic.detail.(toml.Clone_Data_Error_Kind)
		testing.expect(t, detail_ok)
		if detail_ok {testing.expect_value(t, kind, toml.Clone_Data_Error_Kind.Invalid_Temporal)}
		testing.expect_value(t, diagnostic.temporal_error, temporal.Error.Invalid_Day)
		testing.expect_value(t, diagnostic.path.total_segment_count, u16(1))
		name, name_ok := diagnostic.path.segments[0].(string)
		testing.expect(t, name_ok)
		if name_ok {testing.expect_value(t, name, "date")}
		expect_encode_path_shape(t, diagnostic.path)
	}
	mem.arena_free_all(&arena)
}

Deep_00 :: i32
Deep_01 :: []Deep_00
Deep_02 :: []Deep_01
Deep_03 :: []Deep_02
Deep_04 :: []Deep_03
Deep_05 :: []Deep_04
Deep_06 :: []Deep_05
Deep_07 :: []Deep_06
Deep_08 :: []Deep_07
Deep_09 :: []Deep_08
Deep_10 :: []Deep_09
Deep_11 :: []Deep_10
Deep_12 :: []Deep_11
Deep_13 :: []Deep_12
Deep_14 :: []Deep_13
Deep_15 :: []Deep_14
Deep_16 :: []Deep_15
Deep_17 :: []Deep_16
Deep_18 :: []Deep_17
Deep_19 :: []Deep_18
Deep_20 :: []Deep_19
Deep_21 :: []Deep_20
Deep_22 :: []Deep_21
Deep_23 :: []Deep_22
Deep_24 :: []Deep_23
Deep_25 :: []Deep_24
Deep_26 :: []Deep_25
Deep_27 :: []Deep_26
Deep_28 :: []Deep_27
Deep_29 :: []Deep_28
Deep_30 :: []Deep_29
Deep_31 :: []Deep_30
Deep_32 :: []Deep_31
Deep_33 :: []Deep_32

Deep_Destination :: struct {value: Deep_33}

nested_array_input :: proc(depth: int) -> []byte {
	bytes, err := make([]byte, 8+depth*2+2)
	assert(err == nil)
	copy(bytes, "value = ")
	for index in 0..<depth {bytes[8+index] = '['}
	bytes[8+depth] = '1'
	for index in 0..<depth {bytes[9+depth+index] = ']'}
	bytes[len(bytes)-1] = '\n'
	return bytes
}

@(test)
test_unmarshal_wraps_deep_parse_path_with_exact_first_and_last_segments :: proc(t: ^testing.T) {
	input := nested_array_input(33)
	defer delete(input)
	destination: Deep_Destination
	err := toml.unmarshal(input, &destination, {max_depth = 32})
	wrapped, wrapped_ok := err.(toml.Unmarshal_Parse_Error)
	testing.expect(t, wrapped_ok)
	if !wrapped_ok {return}
	diagnostic, ok := wrapped.error.(toml.Parse_Diagnostic)
	testing.expect(t, ok)
	if !ok {return}
	limit, limit_ok := diagnostic.detail.(toml.Parse_Limit_Error)
	testing.expect(t, limit_ok)
	if limit_ok {
		testing.expect_value(t, limit, toml.Parse_Limit_Error.Maximum_Depth_Exceeded)
	}
	expect_parse_path_shape(t, diagnostic.path)
	testing.expect_value(t, diagnostic.path.total_segment_count, u16(33))
	name, name_ok := diagnostic.path.segments[0].(toml.Parse_Diagnostic_Key)
	testing.expect(t, name_ok)
	if name_ok {testing.expect_value(t, string(name.bytes[:name.prefix_length]), "value")}
	for index in 1..<32 {
		segment, index_ok := diagnostic.path.segments[index].(toml.Path_Index)
		testing.expect(t, index_ok)
		if index_ok {testing.expect_value(t, segment, toml.Path_Index(0))}
	}
}

@(test)
test_marshal_size_overflow_is_structural_and_precedes_storage_access :: proc(t: ^testing.T) {
	storage: u128
	raw := mem.Raw_Slice{
		data = &storage,
		len = max(int)/size_of(u128)+1,
	}
	values := transmute([]u128)raw
	failed, err := toml.marshal(struct {values: []u128}{values})
	testing.expect(t, raw_data(failed) == nil)
	diagnostic, ok := err.(toml.Marshal_Diagnostic)
	testing.expect(t, ok)
	if !ok {return}
	limit, limit_ok := diagnostic.detail.(toml.Marshal_Limit_Error)
	testing.expect(t, limit_ok)
	if limit_ok {testing.expect_value(t, limit, toml.Marshal_Limit_Error.Size_Overflow)}
	testing.expect_value(t, diagnostic.path.total_segment_count, u16(1))
	expect_encode_path_shape(t, diagnostic.path)
	name, name_ok := diagnostic.path.segments[0].(string)
	testing.expect(t, name_ok)
	if name_ok {testing.expect_value(t, name, "values")}
}

@(test)
test_marshal_deep_path_preserves_exact_first_and_last_segments :: proc(t: ^testing.T) {
	layers: [33][]any
	for index in 0..<len(layers) {
		selected := index%2
		layer, allocation_error := make([]any, selected+1)
		assert(allocation_error == nil)
		for &item in layer {item = i32(0)}
		layers[index] = layer
	}
	defer for layer in layers {delete(layer)}
	layers[32][32%2] = i128(max(i64))+1
	for index := 31; index >= 0; index -= 1 {
		layers[index][index%2] = layers[index+1]
	}
	failed, err := toml.marshal(struct {value: any}{value = layers[0]})
	testing.expect(t, raw_data(failed) == nil)
	diagnostic, ok := err.(toml.Marshal_Diagnostic)
	testing.expect(t, ok)
	if !ok {return}
	data, data_ok := diagnostic.detail.(toml.Marshal_Data_Error)
	testing.expect(t, data_ok)
	if data_ok {
		testing.expect_value(t, data, toml.Marshal_Data_Error{
			kind = .Integer_Out_Of_Range,
			source_type = typeid_of(i128),
		})
	}
	expect_encode_path_shape(t, diagnostic.path)
	testing.expect_value(t, diagnostic.path.total_segment_count, u16(34))
	name, name_ok := diagnostic.path.segments[0].(string)
	testing.expect(t, name_ok)
	if name_ok {testing.expect_value(t, name, "value")}
	for stored_index in 1..<32 {
		original_path_index := stored_index
		if stored_index >= 8 {original_path_index += 2}
		layer_index := original_path_index-1
		segment, index_ok := diagnostic.path.segments[stored_index].(toml.Path_Index)
		testing.expect(t, index_ok)
		if index_ok {
			testing.expect_value(t, segment, toml.Path_Index(layer_index%2))
		}
	}
}

Invalid_Value_Codec :: distinct i32

marshal_invalid_union :: proc(
	source: any,
	user_data: rawptr,
	allocator: mem.Allocator,
	loc: runtime.Source_Code_Location,
) -> (toml.Value, toml.Codec_Callback_Error) {
	_, _, _, _ = source, user_data, allocator, loc
	value := toml.Value(toml.Integer(1))
	reflect.set_union_variant_raw_tag(value, 255)
	return value, nil
}

@(test)
test_marshal_codec_invalid_value_state_payload_is_exact :: proc(t: ^testing.T) {
	registry, registry_error := toml.init_codec_registry()
	assert(registry_error == nil)
	defer toml.destroy_codec_registry(&registry)
	assert(toml.register_marshaler(
		&registry,
		typeid_of(Invalid_Value_Codec),
		{procedure = marshal_invalid_union},
	) == nil)
	failed, err := toml.marshal(
		struct {value: Invalid_Value_Codec}{1},
		{codecs = &registry},
	)
	testing.expect(t, raw_data(failed) == nil)
	diagnostic, ok := err.(toml.Marshal_Diagnostic)
	testing.expect(t, ok)
	if !ok {return}
	data, data_ok := diagnostic.detail.(toml.Marshal_Data_Error)
	testing.expect(t, data_ok)
	if data_ok {testing.expect_value(t, data, toml.Marshal_Data_Error{
		kind = .Invalid_Value_State,
		source_type = typeid_of(Invalid_Value_Codec),
	})}
	testing.expect_value(t, diagnostic.path.total_segment_count, u16(1))
	expect_encode_path_shape(t, diagnostic.path)
	name, name_ok := diagnostic.path.segments[0].(string)
	testing.expect(t, name_ok)
	if name_ok {testing.expect_value(t, name, "value")}
}

@(test)
test_encode_paths_borrow_stable_application_and_document_keys :: proc(t: ^testing.T) {
	mapping := make(map[string]u128)
	defer delete(mapping)
	mapping["é-map-key"] = u128(max(i64))+1
	failed, marshal_error := toml.marshal(struct {values: map[string]u128}{mapping})
	testing.expect(t, raw_data(failed) == nil)
	marshal_diagnostic, marshal_ok := marshal_error.(toml.Marshal_Diagnostic)
	testing.expect(t, marshal_ok)
	if marshal_ok {
		data, data_ok := marshal_diagnostic.detail.(toml.Marshal_Data_Error)
		testing.expect(t, data_ok)
		if data_ok {
			testing.expect_value(t, data, toml.Marshal_Data_Error{
				kind = .Integer_Out_Of_Range,
				source_type = typeid_of(u128),
			})
		}
		expect_encode_path_shape(t, marshal_diagnostic.path)
		root, root_ok := marshal_diagnostic.path.segments[0].(string)
		key, key_ok := marshal_diagnostic.path.segments[1].(string)
		testing.expect(t, root_ok && key_ok)
		if root_ok {testing.expect_value(t, root, "values")}
		if key_ok {
			testing.expect_value(t, key, "é-map-key")
			for application_key in mapping {
				testing.expect(t, raw_data(key) == raw_data(application_key))
			}
		}
	}

	doc, parse_error := toml.parse_string("date = 2024-02-29\n")
	assert(parse_error == nil)
	defer toml.destroy_document(&doc)
	doc.root[0].value = toml.Value(temporal.Local_Date{2024, 2, 30})
	output, unparse_error := toml.unparse(&doc)
	testing.expect(t, raw_data(output) == nil)
	unparse_diagnostic, unparse_ok := unparse_error.(toml.Unparse_Diagnostic)
	testing.expect(t, unparse_ok)
	if unparse_ok {
		kind, detail_ok := unparse_diagnostic.detail.(toml.Unparse_Data_Error_Kind)
		testing.expect(t, detail_ok)
		if detail_ok {testing.expect_value(t, kind, toml.Unparse_Data_Error_Kind.Invalid_Temporal)}
		testing.expect_value(t, unparse_diagnostic.temporal_error, temporal.Error.Invalid_Day)
		expect_encode_path_shape(t, unparse_diagnostic.path)
		key, key_ok := unparse_diagnostic.path.segments[0].(string)
		testing.expect(t, key_ok)
		if key_ok {
			testing.expect_value(t, key, doc.root[0].key)
			testing.expect(t, raw_data(key) == raw_data(doc.root[0].key))
		}
	}
}

Payload_Destination :: struct {
	integer: i8,
	float:   f32,
	fixed:   [2]i32,
	boolean: i32,
}

@(test)
test_unmarshal_payload_types_kinds_counts_ranges_and_input_lifetime_are_exact :: proc(t: ^testing.T) {
	cases := [?]struct {
		input:          string,
		expected:       toml.Unmarshal_Data_Error,
		path:           string,
		start, end:     int,
	}{
		{"integer = 128\n", {
			kind = .Integer_Out_Of_Range,
			destination_type = typeid_of(i8),
			source_kind = .Integer,
		}, "integer", 10, 13},
		{"float = 1e100\n", {
			kind = .Float_Out_Of_Range,
			destination_type = typeid_of(f32),
			source_kind = .Float,
		}, "float", 8, 13},
		{"fixed = [1]\n", {
			kind = .Fixed_Array_Length_Mismatch,
			destination_type = typeid_of([2]i32),
			source_kind = .Array,
			expected_count = 2,
			actual_count = 1,
		}, "fixed", 8, 11},
		{"boolean = true\n", {
			kind = .Source_Destination_Kind_Mismatch,
			destination_type = typeid_of(i32),
			source_kind = .Boolean,
		}, "boolean", 10, 14},
	}
	for test_case in cases {
		input, allocation_error := make([]byte, len(test_case.input))
		assert(allocation_error == nil)
		copy(input, transmute([]byte)test_case.input)
		destination: Payload_Destination
		err := toml.unmarshal(input, &destination)
		for &byte in input {byte = 0}
		delete(input)
		diagnostic, ok := err.(toml.Unmarshal_Diagnostic)
		testing.expect(t, ok)
		if !ok {continue}
		data, data_ok := diagnostic.detail.(toml.Unmarshal_Data_Error)
		testing.expect(t, data_ok)
		if data_ok {testing.expect_value(t, data, test_case.expected)}
		testing.expect(t, diagnostic.source.ok)
		if diagnostic.source.ok {
			testing.expect_value(t, diagnostic.source.value.start.byte, test_case.start)
			testing.expect_value(t, diagnostic.source.value.end.byte, test_case.end)
		}
		testing.expect_value(t, diagnostic.path.total_segment_count, u16(1))
		expect_encode_path_shape(t, diagnostic.path)
		name, name_ok := diagnostic.path.segments[0].(string)
		testing.expect(t, name_ok)
		if name_ok {testing.expect_value(t, name, test_case.path)}
	}
}

expect_kind_mismatch :: proc(
	t: ^testing.T,
	input: string,
	destination: ^$T,
	expected_type: typeid,
	expected_kind: toml.Value_Kind,
) {
	err := toml.unmarshal_string(input, destination)
	diagnostic, ok := err.(toml.Unmarshal_Diagnostic)
	testing.expect(t, ok)
	if !ok {return}
	data, data_ok := diagnostic.detail.(toml.Unmarshal_Data_Error)
	testing.expect(t, data_ok)
	if data_ok {testing.expect_value(t, data, toml.Unmarshal_Data_Error{
		kind = .Source_Destination_Kind_Mismatch,
		destination_type = expected_type,
		source_kind = expected_kind,
	})}
	testing.expect(t, diagnostic.source.ok)
	testing.expect_value(t, diagnostic.path.total_segment_count, u16(1))
	expect_encode_path_shape(t, diagnostic.path)
}

@(test)
test_unmarshal_kind_mismatch_reports_every_source_value_kind_exactly :: proc(t: ^testing.T) {
	integer_destination := struct {value: bool}{}
	expect_kind_mismatch(t, "value = 1\n", &integer_destination, typeid_of(bool), .Integer)
	float_destination := struct {value: bool}{}
	expect_kind_mismatch(t, "value = 1.5\n", &float_destination, typeid_of(bool), .Float)
	string_destination := struct {value: i32}{}
	expect_kind_mismatch(t, "value = \"text\"\n", &string_destination, typeid_of(i32), .String)
	boolean_destination := struct {value: i32}{}
	expect_kind_mismatch(t, "value = true\n", &boolean_destination, typeid_of(i32), .Boolean)
	offset_destination := struct {value: i32}{}
	expect_kind_mismatch(t, "value = 2024-01-01T00:00:00Z\n", &offset_destination, typeid_of(i32), .Offset_Date_Time)
	local_stamp_destination := struct {value: i32}{}
	expect_kind_mismatch(t, "value = 2024-01-01T00:00:00\n", &local_stamp_destination, typeid_of(i32), .Local_Date_Time)
	date_destination := struct {value: i32}{}
	expect_kind_mismatch(t, "value = 2024-01-01\n", &date_destination, typeid_of(i32), .Local_Date)
	time_destination := struct {value: i32}{}
	expect_kind_mismatch(t, "value = 00:00:00\n", &time_destination, typeid_of(i32), .Local_Time)
	array_destination := struct {value: i32}{}
	expect_kind_mismatch(t, "value = []\n", &array_destination, typeid_of(i32), .Array)
	table_destination := struct {value: i32}{}
	expect_kind_mismatch(t, "value = {}\n", &table_destination, typeid_of(i32), .Table)
}

Unsupported_Destination :: struct {callback: proc()}
Malformed_Destination :: struct {value: i32 `toml:"value,unknown"`}
Collision_Destination :: struct {
	first:  i32 `toml:"same"`,
	second: i32 `toml:"same"`,
}
Unknown_Destination :: struct {}
Nonzero_Destination :: struct {text: string}
Unicode_Tag_Destination :: struct {value: i32 `toml:"véalue"`}

@(test)
test_unmarshal_root_type_tag_field_unknown_and_ownership_payloads_are_exact :: proc(t: ^testing.T) {
	scalar := i32(7)
	err := toml.unmarshal_string("value = 1\n", &scalar)
	diagnostic, ok := err.(toml.Unmarshal_Diagnostic)
	testing.expect(t, ok)
	if ok {
		data, data_ok := diagnostic.detail.(toml.Unmarshal_Data_Error)
		testing.expect(t, data_ok)
		if data_ok {testing.expect_value(t, data, toml.Unmarshal_Data_Error{
			kind = .Invalid_Root_Shape,
			destination_type = typeid_of(i32),
			source_kind = .Table,
		})}
		testing.expect_value(t, diagnostic.source, toml.Optional_Source_Range{})
		testing.expect_value(t, diagnostic.path, toml.Encode_Diagnostic_Path{})
	}

	unsupported: Unsupported_Destination
	err = toml.unmarshal_string("callback = 1\n", &unsupported)
	diagnostic, ok = err.(toml.Unmarshal_Diagnostic)
	testing.expect(t, ok)
	if ok {
		data, data_ok := diagnostic.detail.(toml.Unmarshal_Data_Error)
		testing.expect(t, data_ok)
		if data_ok {testing.expect_value(t, data, toml.Unmarshal_Data_Error{
			kind = .Unsupported_Destination_Type,
			destination_type = typeid_of(proc()),
		})}
		testing.expect_value(t, diagnostic.source, toml.Optional_Source_Range{})
		testing.expect_value(t, diagnostic.path, toml.Encode_Diagnostic_Path{})
	}

	malformed: Malformed_Destination
	err = toml.unmarshal_string("value = 1\n", &malformed)
	diagnostic, ok = err.(toml.Unmarshal_Diagnostic)
	testing.expect(t, ok)
	if ok {
		data, data_ok := diagnostic.detail.(toml.Unmarshal_Data_Error)
		testing.expect(t, data_ok)
		if data_ok {testing.expect_value(t, data, toml.Unmarshal_Data_Error{
			kind = .Malformed_Tag,
			destination_type = typeid_of(i32),
		})}
		testing.expect_value(t, diagnostic.source, toml.Optional_Source_Range{})
		testing.expect_value(t, diagnostic.path, toml.Encode_Diagnostic_Path{})
	}

	collision: Collision_Destination
	err = toml.unmarshal_string("same = 1\n", &collision)
	diagnostic, ok = err.(toml.Unmarshal_Diagnostic)
	testing.expect(t, ok)
	if ok {
		data, data_ok := diagnostic.detail.(toml.Unmarshal_Data_Error)
		testing.expect(t, data_ok)
		if data_ok {testing.expect_value(t, data, toml.Unmarshal_Data_Error{
			kind = .Effective_Field_Name_Collision,
			destination_type = typeid_of(i32),
			related_type = typeid_of(i32),
		})}
		testing.expect_value(t, diagnostic.source, toml.Optional_Source_Range{})
		testing.expect_value(t, diagnostic.path, toml.Encode_Diagnostic_Path{})
	}

	unknown: Unknown_Destination
	err = toml.unmarshal_string("\"unknown\" = 1\n", &unknown, {reject_unknown_fields = true})
	diagnostic, ok = err.(toml.Unmarshal_Diagnostic)
	testing.expect(t, ok)
	if ok {
		data, data_ok := diagnostic.detail.(toml.Unmarshal_Data_Error)
		testing.expect(t, data_ok)
		if data_ok {testing.expect_value(t, data, toml.Unmarshal_Data_Error{
			kind = .Unknown_Field,
			destination_type = typeid_of(Unknown_Destination),
			source_kind = .Integer,
		})}
		testing.expect(t, diagnostic.source.ok)
		if diagnostic.source.ok {
			testing.expect_value(t, diagnostic.source.value, toml.Source_Range{
				start = {byte = 0, line = 1, column = 1},
				end = {byte = 9, line = 1, column = 10},
			})
		}
		testing.expect_value(t, diagnostic.path, toml.Encode_Diagnostic_Path{})
	}

	nonzero := Nonzero_Destination{text = "application"}
	err = toml.unmarshal_string("text = \"source\"\n", &nonzero)
	diagnostic, ok = err.(toml.Unmarshal_Diagnostic)
	testing.expect(t, ok)
	if ok {
		data, data_ok := diagnostic.detail.(toml.Unmarshal_Data_Error)
		testing.expect(t, data_ok)
		if data_ok {testing.expect_value(t, data, toml.Unmarshal_Data_Error{
			kind = .Nonzero_Destination_Ownership,
			destination_type = typeid_of(string),
			source_kind = .String,
		})}
		testing.expect(t, diagnostic.source.ok)
		testing.expect_value(t, diagnostic.path.total_segment_count, u16(1))
		expect_encode_path_shape(t, diagnostic.path)
	}
}

@(test)
test_unmarshal_unicode_escape_tab_crlf_range_and_tag_path_outlive_input :: proc(t: ^testing.T) {
	text := "ok = 1\r\n\"vé\\u0061lue\"\t= true\n"
	input, allocation_error := make([]byte, len(text))
	assert(allocation_error == nil)
	copy(input, transmute([]byte)text)
	destination: Unicode_Tag_Destination
	err := toml.unmarshal(input, &destination, {reject_unknown_fields = false})
	for &byte in input {byte = 0}
	delete(input)
	diagnostic, ok := err.(toml.Unmarshal_Diagnostic)
	testing.expect(t, ok)
	if !ok {return}
	data, data_ok := diagnostic.detail.(toml.Unmarshal_Data_Error)
	testing.expect(t, data_ok)
	if data_ok {testing.expect_value(t, data, toml.Unmarshal_Data_Error{
		kind = .Source_Destination_Kind_Mismatch,
		destination_type = typeid_of(i32),
		source_kind = .Boolean,
	})}
	testing.expect(t, diagnostic.source.ok)
	if diagnostic.source.ok {
		testing.expect_value(t, diagnostic.source.value, toml.Source_Range{
			start = {byte = 25, line = 2, column = 17},
			end = {byte = 29, line = 2, column = 21},
		})
	}
	testing.expect_value(t, diagnostic.path.total_segment_count, u16(1))
	expect_encode_path_shape(t, diagnostic.path)
	name, name_ok := diagnostic.path.segments[0].(string)
	testing.expect(t, name_ok)
	if name_ok {testing.expect_value(t, name, "véalue")}
}

@(test)
test_configuration_registry_allocator_writer_and_nil_success_precedence_is_exact :: proc(t: ^testing.T) {
	nil_allocator: mem.Allocator
	invalid_registry: toml.Codec_Registry
	invalid_options := toml.Marshal_Options{max_depth = 257, codecs = &invalid_registry}
	bytes, marshal_error := toml.marshal(struct {value: i32}{1}, invalid_options, nil_allocator)
	testing.expect(t, raw_data(bytes) == nil)
	testing.expect_value(t, marshal_error, toml.Marshal_Configuration_Error.Invalid_Allocator)

	calls: [8]test_support.Scripted_Writer_Call
	requested: [64]byte
	writer_state: test_support.Scripted_Writer
	test_support.scripted_writer_init(&writer_state, nil, calls[:], requested[:])
	writer_error := toml.marshal_to_writer(
		test_support.scripted_writer(&writer_state), struct {value: i32}{1}, nil,
	)
	testing.expect_value(t, writer_error, toml.Marshal_Configuration_Error.Nil_Options)
	testing.expect_value(t, writer_state.write_count, 0)

	invalid_depth_only := toml.Marshal_Options{max_depth = 257, codecs = &invalid_registry}
	test_support.scripted_writer_init(&writer_state, nil, calls[:], requested[:])
	writer_error = toml.marshal_to_writer(
		test_support.scripted_writer(&writer_state), struct {value: i32}{1}, &invalid_depth_only,
	)
	testing.expect_value(t, writer_error, toml.Marshal_Configuration_Error.Invalid_Max_Depth)
	testing.expect_value(t, writer_state.write_count, 0)

	unparse_doc, parse_error := toml.parse_string("")
	assert(parse_error == nil)
	defer toml.destroy_document(&unparse_doc)
	unparse_options := toml.Marshal_Options{codecs = &invalid_registry}
	output, unparse_error := toml.unparse(&unparse_doc, unparse_options)
	testing.expect(t, unparse_error == nil)
	testing.expect(t, raw_data(output) == nil)

	destination := struct {value: i32}{}
	unmarshal_error := toml.unmarshal_string(
		"not toml", &destination,
		{max_depth = 257, codecs = &invalid_registry}, nil_allocator,
	)
	testing.expect_value(t, unmarshal_error, toml.Unmarshal_Configuration_Error.Invalid_Allocator)
	unmarshal_error = toml.unmarshal_string(
		"not toml", &destination, {max_depth = 257, codecs = &invalid_registry},
	)
	testing.expect_value(t, unmarshal_error, toml.Unmarshal_Configuration_Error.Invalid_Max_Depth)
	nil_destination: ^struct {value: i32}
	unmarshal_error = toml.unmarshal_string(
		"not toml", nil_destination, {codecs = &invalid_registry},
	)
	testing.expect_value(t, unmarshal_error, toml.Unmarshal_Configuration_Error.Nil_Destination)
}

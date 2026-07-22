package container_parse_test

import "base:runtime"
import "core:mem"
import "core:testing"
import toml "../.."
import temporal "../../vendor/temporal"
import test_support "../support"

document_is_zero :: proc(doc: toml.Document) -> bool {
	return raw_data(doc.root) == nil && len(doc.root) == 0 && cap(doc.root) == 0 &&
	       doc.root.allocator.procedure == nil && doc.allocator.procedure == nil
}

parse_diagnostic_from :: proc(err: toml.Parse_Error) -> (toml.Parse_Diagnostic, bool) {
	return err.(toml.Parse_Diagnostic)
}

mutable_bytes :: proc(text: string) -> []byte {
	bytes, err := make([]byte, len(text))
	assert(err == nil)
	copy(bytes, transmute([]byte)text)
	return bytes
}

nested_array_document :: proc(array_count: int) -> []byte {
	bytes, err := make([]byte, 3+array_count*2+1)
	assert(err == nil)
	copy(bytes, "v =")
	for index in 0..<array_count {
		bytes[3+index] = '['
		bytes[3+array_count+index] = ']'
	}
	bytes[len(bytes)-1] = '\n'
	return bytes
}

inline_dotted_document :: proc(component_count: int) -> []byte {
	bytes, err := make([]byte, component_count*2+6)
	assert(err == nil)
	copy(bytes, "v={")
	index := 3
	for component in 0..<component_count {
		bytes[index] = 'a'
		index += 1
		if component+1 < component_count {
			bytes[index] = '.'
			index += 1
		}
	}
	copy(bytes[index:], "=0}\n")
	return bytes
}

value_for :: proc(t: ^testing.T, doc: ^toml.Document, key: string) -> ^toml.Value {
	value, ok := toml.get(&doc.root, key)
	testing.expect(t, ok)
	return value
}

@(test)
test_arrays_preserve_heterogeneous_order_and_nested_multiline_values :: proc(t: ^testing.T) {
	input := `values = [
  1,
  # every TOML value kind may be mixed
  "two",
  true,
  [3, 4,],
]
`
	doc, err := toml.parse_string(input)
	testing.expect(t, err == nil)
	if err != nil {
		return
	}
	defer toml.destroy_document(&doc)

	values, ok := value_for(t, &doc, "values").(toml.Array)
	testing.expect(t, ok)
	testing.expect_value(t, len(values), 4)
	first, first_ok := values[0].(toml.Integer)
	testing.expect(t, first_ok)
	testing.expect_value(t, first, toml.Integer(1))
	second, second_ok := values[1].(toml.String)
	testing.expect(t, second_ok)
	testing.expect_value(t, second, "two")
	third, third_ok := values[2].(toml.Boolean)
	testing.expect(t, third_ok)
	testing.expect(t, third)
	nested, nested_ok := values[3].(toml.Array)
	testing.expect(t, nested_ok)
	testing.expect_value(t, len(nested), 2)
	fourth, fourth_ok := nested[1].(toml.Integer)
	testing.expect(t, fourth_ok)
	testing.expect_value(t, fourth, toml.Integer(4))
}

@(test)
test_parser_grows_semantic_array_storage_geometrically :: proc(t: ^testing.T) {
	events: [64]test_support.Allocator_Event
	live: [32]test_support.Live_Allocation
	observed: test_support.Observed_Allocator
	test_support.observed_allocator_init(
		&observed, context.allocator, events[:], live[:],
	)
	doc, err := toml.parse_string(
		"values = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]\n",
		allocator = test_support.observed_allocator(&observed),
	)
	testing.expect(t, err == nil)
	if err != nil {
		return
	}
	values, values_ok := doc.root[0].value.(toml.Array)
	testing.expect(t, values_ok)
	testing.expect_value(t, len(values), 17)
	testing.expect_value(t, cap(values), 32)
	// One key, one root table, one parser-node buffer, and six array buffers.
	testing.expect(t, observed.allocation_request_count <= 9)
	toml.destroy_document(&doc)
	testing.expect_value(t, observed.live_count, 0)
	testing.expect_value(t, observed.foreign_release_count, 0)
}

@(test)
test_arrays_accept_every_toml_value_kind :: proc(t: ^testing.T) {
	doc, err := toml.parse_string(
		`v = ["s", 1, 1.5, true, 1979-05-27T07:32Z, 1979-05-27T07:32, 1979-05-27, 07:32, [], {}]
`,
	)
	testing.expect(t, err == nil)
	if err != nil {
		return
	}
	defer toml.destroy_document(&doc)
	values, ok := value_for(t, &doc, "v").(toml.Array)
	testing.expect(t, ok)
	testing.expect_value(t, len(values), 10)
	_, string_ok := values[0].(toml.String)
	_, integer_ok := values[1].(toml.Integer)
	_, float_ok := values[2].(toml.Float)
	_, boolean_ok := values[3].(toml.Boolean)
	_, offset_ok := values[4].(temporal.Offset_Date_Time)
	_, local_datetime_ok := values[5].(temporal.Local_Date_Time)
	_, local_date_ok := values[6].(temporal.Local_Date)
	_, local_time_ok := values[7].(temporal.Local_Time)
	_, array_ok := values[8].(toml.Array)
	_, table_ok := values[9].(toml.Table)
	testing.expect(t, string_ok && integer_ok && float_ok && boolean_ok)
	testing.expect(t, offset_ok && local_datetime_ok && local_date_ok && local_time_ok)
	testing.expect(t, array_ok && table_ok)
}

@(test)
test_nested_container_keys_and_strings_never_borrow_byte_input :: proc(t: ^testing.T) {
	input := mutable_bytes(`outer = [{ "escaped\u002Ekey" = "owned value" }]`)
	defer delete(input)
	doc, err := toml.parse_bytes(input)
	testing.expect(t, err == nil)
	if err != nil {
		return
	}
	defer toml.destroy_document(&doc)
	for &byte in input {
		byte = 'x'
	}
	outer, outer_ok := value_for(t, &doc, "outer").(toml.Array)
	testing.expect(t, outer_ok)
	table, table_ok := outer[0].(toml.Table)
	testing.expect(t, table_ok)
	testing.expect_value(t, table[0].key, "escaped.key")
	text, text_ok := table[0].value.(toml.String)
	testing.expect(t, text_ok)
	testing.expect_value(t, text, "owned value")
}

@(test)
test_inline_tables_preserve_order_and_resolve_local_dotted_paths :: proc(t: ^testing.T) {
	input := `first = {
  dotted.child = 1,
  # TOML 1.1 permits this trivia and a trailing comma
  dotted.other = [true, { nested = "yes" }],
  direct = 2,
}
second = { dotted = 3 }
`
	doc, err := toml.parse_string(input)
	testing.expect(t, err == nil)
	if err != nil {
		return
	}
	defer toml.destroy_document(&doc)

	first, ok := value_for(t, &doc, "first").(toml.Table)
	testing.expect(t, ok)
	testing.expect_value(t, len(first), 2)
	testing.expect_value(t, first[0].key, "dotted")
	testing.expect_value(t, first[1].key, "direct")
	dotted, dotted_ok := first[0].value.(toml.Table)
	testing.expect(t, dotted_ok)
	testing.expect_value(t, len(dotted), 2)
	testing.expect_value(t, dotted[0].key, "child")
	testing.expect_value(t, dotted[1].key, "other")
	other, other_ok := dotted[1].value.(toml.Array)
	testing.expect(t, other_ok)
	nested, nested_ok := other[1].(toml.Table)
	testing.expect(t, nested_ok)
	nested_text, nested_text_ok := nested[0].value.(toml.String)
	testing.expect(t, nested_text_ok)
	testing.expect_value(t, nested_text, "yes")

	second, second_ok := value_for(t, &doc, "second").(toml.Table)
	testing.expect(t, second_ok)
	testing.expect_value(t, second[0].key, "dotted")
	second_value, second_value_ok := second[0].value.(toml.Integer)
	testing.expect(t, second_value_ok)
	testing.expect_value(t, second_value, toml.Integer(3))
}

@(test)
test_container_separator_comment_and_child_errors_have_exact_categories_ranges_and_paths :: proc(t: ^testing.T) {
	grammar_cases := [?]struct {
		input:       string,
		expected:    toml.Parse_Syntax,
		found:       toml.Parse_Syntax,
		range_start: int,
		range_end:   int,
		path_count:  u8,
	}{
		{"value = [1 2]\n", .Comma, .Other, 11, 12, 2},
		{"value = [1,,2]\n", .Value, .Comma, 11, 12, 2},
		{"value = {a=1 b=2}\n", .Comma, .Other, 13, 14, 2},
		{"value = {a=1,,}\n", .Key, .Comma, 13, 14, 1},
		{"value = [1] trailing\n", .Expression_End, .Other, 12, 13, 1},
		{"value = {a=1} trailing\n", .Expression_End, .Other, 14, 15, 1},
	}
	for test_case in grammar_cases {
		doc, err := toml.parse_string(test_case.input)
		testing.expect(t, document_is_zero(doc))
		diagnostic, ok := parse_diagnostic_from(err)
		testing.expect(t, ok)
		grammar, grammar_ok := diagnostic.detail.(toml.Parse_Grammar_Error)
		testing.expect(t, grammar_ok)
		testing.expect(t, test_case.expected in grammar.expected)
		testing.expect_value(t, grammar.found, test_case.found)
		testing.expect_value(t, diagnostic.primary.start.byte, test_case.range_start)
		testing.expect_value(t, diagnostic.primary.end.byte, test_case.range_end)
		testing.expect_value(t, diagnostic.path.segment_count, test_case.path_count)
	}

	comment_doc, comment_error := toml.parse_string("value = [1 # bad\x01\n]\n")
	testing.expect(t, document_is_zero(comment_doc))
	comment_diagnostic, comment_ok := parse_diagnostic_from(comment_error)
	testing.expect(t, comment_ok)
	lexical, lexical_ok := comment_diagnostic.detail.(toml.Parse_Lexical_Error)
	testing.expect(t, lexical_ok)
	testing.expect_value(t, lexical, toml.Parse_Lexical_Error.Invalid_Comment_Character)
	testing.expect_value(t, comment_diagnostic.primary.start.byte, 16)
	testing.expect_value(t, comment_diagnostic.primary.end.byte, 17)
	testing.expect_value(t, comment_diagnostic.path.segment_count, u8(2))

	child_doc, child_error := toml.parse_string("value = [0xG]\n")
	testing.expect(t, document_is_zero(child_doc))
	child_diagnostic, child_ok := parse_diagnostic_from(child_error)
	testing.expect(t, child_ok)
	value_error, value_error_ok := child_diagnostic.detail.(toml.Parse_Value_Error)
	testing.expect(t, value_error_ok)
	testing.expect_value(t, value_error.kind, toml.Parse_Value_Error_Kind.Invalid_Integer)
	testing.expect_value(t, child_diagnostic.primary.start.byte, 11)
	testing.expect_value(t, child_diagnostic.primary.end.byte, 12)
	index_segment, index_ok := child_diagnostic.path.segments[1].(toml.Path_Index)
	testing.expect(t, index_ok)
	testing.expect_value(t, index_segment, toml.Path_Index(0))
}

@(test)
test_inline_duplicate_dotted_redefinition_and_sealed_extension_report_related_definitions :: proc(t: ^testing.T) {
	cases := [?]struct {
		input:         string,
		kind:          toml.Parse_Definition_Error_Kind,
		primary_start: int,
		primary_end:   int,
		related_start: int,
		related_end:   int,
		path_count:    u8,
	}{
		{"v={a=1,a=2}\n", .Duplicate_Key, 7, 8, 3, 6, 2},
		{"v={a.b=1,a=2}\n", .Dotted_Table_Redefined, 9, 10, 3, 4, 2},
		{"v={a={b=1},a.c=2}\n", .Inline_Table_Extended, 11, 12, 3, 10, 3},
		{"v={a=1,a.b=2}\n", .Non_Table_Path_Component, 7, 8, 3, 6, 3},
	}
	for test_case in cases {
		doc, err := toml.parse_string(test_case.input)
		testing.expect(t, document_is_zero(doc))
		diagnostic, ok := parse_diagnostic_from(err)
		testing.expect(t, ok)
		definition, definition_ok := diagnostic.detail.(toml.Parse_Definition_Error)
		testing.expect(t, definition_ok)
		testing.expect_value(t, definition.kind, test_case.kind)
		testing.expect_value(t, diagnostic.primary.start.byte, test_case.primary_start)
		testing.expect_value(t, diagnostic.primary.end.byte, test_case.primary_end)
		testing.expect(t, diagnostic.related.ok)
		testing.expect_value(t, diagnostic.related.value.start.byte, test_case.related_start)
		testing.expect_value(t, diagnostic.related.value.end.byte, test_case.related_end)
		testing.expect_value(t, diagnostic.path.segment_count, test_case.path_count)
	}
}

@(test)
test_container_depth_counts_semantic_keys_and_indexes :: proc(t: ^testing.T) {
	valid_cases := [?]struct {
		input: string,
		depth: int,
	}{
		{"v=[]\n", 1},
		{"v={}\n", 1},
		{"v=[0]\n", 2},
		{"v={a=0}\n", 2},
		{"v=[{a=0}]\n", 3},
		{"v={a=[0]}\n", 3},
	}
	for test_case in valid_cases {
		doc, err := toml.parse_string(test_case.input, {max_depth = test_case.depth})
		testing.expect(t, err == nil)
		if err == nil {
			toml.destroy_document(&doc)
		}
	}

	invalid_cases := [?]struct {
		input:       string,
		depth:       int,
		range_start: int,
		path_count:  u8,
	}{
		{"v=[0]\n", 1, 3, 2},
		{"v={a=0}\n", 1, 3, 2},
		{"v=[{a=0}]\n", 2, 4, 3},
		{"v={a=[0]}\n", 2, 6, 3},
	}
	for test_case in invalid_cases {
		doc, err := toml.parse_string(test_case.input, {max_depth = test_case.depth})
		testing.expect(t, document_is_zero(doc))
		diagnostic, ok := parse_diagnostic_from(err)
		testing.expect(t, ok)
		limit, limit_ok := diagnostic.detail.(toml.Parse_Limit_Error)
		testing.expect(t, limit_ok)
		testing.expect_value(t, limit, toml.Parse_Limit_Error.Maximum_Depth_Exceeded)
		testing.expect_value(t, diagnostic.primary.start.byte, test_case.range_start)
		testing.expect_value(t, diagnostic.path.segment_count, test_case.path_count)
	}
}

@(test)
test_over_depth_inline_keys_are_rejected_before_owned_key_allocation :: proc(t: ^testing.T) {
	cases := [?]struct {
		input:           string,
		expected_prefix: string,
		expected_suffix: string,
		key_truncated:   bool,
	}{
		{`v={"esc\u0061ped"=0}
`, "escaped", "", false},
		{`v={"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\u03B1cccccccccc\u03B2bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"=0}
`, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", true},
	}
	for test_case in cases {
		events: [64]test_support.Allocator_Event
		live: [16]test_support.Live_Allocation
		observed: test_support.Observed_Allocator
		test_support.observed_allocator_init(&observed, context.allocator, events[:], live[:])
		// The root key is allocation one. Allocation two would be the owned
		// inline key if the semantic-depth check happened too late.
		observed.fail_at_allocation = 2
		allocator := test_support.observed_allocator(&observed)
		doc, err := toml.parse_string(
			test_case.input,
			{max_depth = 1},
			allocator,
		)
		testing.expect(t, document_is_zero(doc))
		diagnostic, ok := parse_diagnostic_from(err)
		testing.expect(t, ok)
		limit, limit_ok := diagnostic.detail.(toml.Parse_Limit_Error)
		testing.expect(t, limit_ok)
		testing.expect_value(t, limit, toml.Parse_Limit_Error.Maximum_Depth_Exceeded)
		testing.expect_value(t, observed.allocation_request_count, 1)
		testing.expect_value(t, observed.live_count, 0)
		testing.expect_value(t, diagnostic.path.segment_count, u8(2))
		key, key_ok := diagnostic.path.segments[1].(toml.Parse_Diagnostic_Key)
		testing.expect(t, key_ok)
		testing.expect_value(t, key.truncated, test_case.key_truncated)
		testing.expect_value(
			t,
			string(key.bytes[:key.prefix_length]),
			test_case.expected_prefix,
		)
		if test_case.key_truncated {
			suffix_start := int(key.prefix_length)
			testing.expect_value(
				t,
				string(key.bytes[suffix_start:suffix_start+int(key.suffix_length)]),
				test_case.expected_suffix,
			)
			testing.expect(t, key.omitted_byte_count > 0)
			testing.expect_value(
				t,
				key.decoded_byte_length,
				int(key.prefix_length)+int(key.suffix_length)+key.omitted_byte_count,
			)
		}
	}
}

@(test)
test_over_depth_inline_key_preflight_preserves_lexical_error_precedence :: proc(t: ^testing.T) {
	events: [64]test_support.Allocator_Event
	live: [16]test_support.Live_Allocation
	observed: test_support.Observed_Allocator
	test_support.observed_allocator_init(&observed, context.allocator, events[:], live[:])
	observed.fail_at_allocation = 2
	allocator := test_support.observed_allocator(&observed)
	doc, err := toml.parse_string(
		`v={"bad\q"=0}
`,
		{max_depth = 1},
		allocator,
	)
	testing.expect(t, document_is_zero(doc))
	diagnostic, ok := parse_diagnostic_from(err)
	testing.expect(t, ok)
	lexical, lexical_ok := diagnostic.detail.(toml.Parse_Lexical_Error)
	testing.expect(t, lexical_ok)
	testing.expect_value(t, lexical, toml.Parse_Lexical_Error.Invalid_Escape)
	testing.expect_value(t, observed.allocation_request_count, 1)
	testing.expect_value(t, observed.live_count, 0)
}

@(test)
test_default_and_explicit_maximum_depth_boundaries_and_truncated_paths_are_exact :: proc(t: ^testing.T) {
	default_valid := nested_array_document(128)
	defer delete(default_valid)
	doc, err := toml.parse_bytes(default_valid)
	testing.expect(t, err == nil)
	if err == nil {
		toml.destroy_document(&doc)
	}

	default_invalid := nested_array_document(129)
	defer delete(default_invalid)
	doc, err = toml.parse_bytes(default_invalid)
	testing.expect(t, document_is_zero(doc))
	diagnostic, ok := parse_diagnostic_from(err)
	testing.expect(t, ok)
	limit, limit_ok := diagnostic.detail.(toml.Parse_Limit_Error)
	testing.expect(t, limit_ok)
	testing.expect_value(t, limit, toml.Parse_Limit_Error.Maximum_Depth_Exceeded)
	testing.expect(t, diagnostic.path.truncated)
	testing.expect_value(t, diagnostic.path.segment_count, u8(32))
	testing.expect_value(t, diagnostic.path.prefix_count, u8(8))
	testing.expect_value(t, diagnostic.path.total_segment_count, u16(129))
	testing.expect_value(t, diagnostic.path.omitted_segment_count, u16(97))

	explicit_valid := nested_array_document(256)
	defer delete(explicit_valid)
	doc, err = toml.parse_bytes(explicit_valid, {max_depth = 256})
	testing.expect(t, err == nil)
	if err == nil {
		toml.destroy_document(&doc)
	}

	explicit_invalid := nested_array_document(257)
	defer delete(explicit_invalid)
	doc, err = toml.parse_bytes(explicit_invalid, {max_depth = 256})
	testing.expect(t, document_is_zero(doc))
	diagnostic, ok = parse_diagnostic_from(err)
	testing.expect(t, ok)
	limit, limit_ok = diagnostic.detail.(toml.Parse_Limit_Error)
	testing.expect(t, limit_ok)
	testing.expect_value(t, limit, toml.Parse_Limit_Error.Maximum_Depth_Exceeded)
	testing.expect_value(t, diagnostic.path.total_segment_count, u16(257))
	testing.expect_value(t, diagnostic.path.omitted_segment_count, u16(225))

	dotted_valid := inline_dotted_document(255)
	defer delete(dotted_valid)
	doc, err = toml.parse_bytes(dotted_valid, {max_depth = 256})
	testing.expect(t, err == nil)
	if err == nil {
		toml.destroy_document(&doc)
	}

	dotted_invalid := inline_dotted_document(256)
	defer delete(dotted_invalid)
	doc, err = toml.parse_bytes(dotted_invalid, {max_depth = 256})
	testing.expect(t, document_is_zero(doc))
	diagnostic, ok = parse_diagnostic_from(err)
	testing.expect(t, ok)
	limit, limit_ok = diagnostic.detail.(toml.Parse_Limit_Error)
	testing.expect(t, limit_ok)
	testing.expect_value(t, limit, toml.Parse_Limit_Error.Maximum_Depth_Exceeded)
	testing.expect_value(t, diagnostic.path.total_segment_count, u16(257))
}

@(test)
test_container_parse_allocation_failure_is_transactional_at_every_ordinal :: proc(t: ^testing.T) {
	input := `container = [
  "owned",
  { dotted.child = "also owned", nested = [1, 2, 3] },
  [{ empty = {} }],
]
`
	backing := context.allocator
	baseline_events: [2048]test_support.Allocator_Event
	baseline_live: [512]test_support.Live_Allocation
	baseline: test_support.Observed_Allocator
	test_support.observed_allocator_init(&baseline, backing, baseline_events[:], baseline_live[:])
	baseline_allocator := test_support.observed_allocator(&baseline)
	baseline_doc, baseline_error := toml.parse_string(input, allocator = baseline_allocator)
	testing.expect(t, baseline_error == nil)
	allocation_count := baseline.allocation_request_count
	if baseline_error == nil {
		toml.destroy_document(&baseline_doc)
	}
	testing.expect(t, allocation_count > 0)
	testing.expect_value(t, baseline.live_count, 0)

	for fail_at in 1..=allocation_count {
		events: [2048]test_support.Allocator_Event
		live: [512]test_support.Live_Allocation
		observed: test_support.Observed_Allocator
		test_support.observed_allocator_init(&observed, backing, events[:], live[:])
		observed.fail_at_allocation = fail_at
		selected := test_support.observed_allocator(&observed)
		rejecting: test_support.Rejecting_Allocator
		context.allocator = test_support.rejecting_allocator(&rejecting)
		doc, err := toml.parse_string(input, allocator = selected)
		context.allocator = backing

		testing.expect(t, document_is_zero(doc))
		allocator_error, ok := err.(runtime.Allocator_Error)
		testing.expect(t, ok)
		testing.expect_value(t, allocator_error, runtime.Allocator_Error.Out_Of_Memory)
		testing.expect_value(t, observed.live_count, 0)
		testing.expect_value(t, observed.foreign_release_count, 0)
		testing.expect_value(t, rejecting.allocation_attempt_count, 0)
	}
	context.allocator = backing
}

@(test)
test_external_lifetime_container_parse_owns_and_logically_destroys_tree :: proc(t: ^testing.T) {
	buffer: [256 * 1024]byte
	arena: mem.Arena
	mem.arena_init(&arena, buffer[:])
	external: test_support.External_Lifetime_Allocator
	test_support.external_lifetime_allocator_init(&external, mem.arena_allocator(&arena), true)
	allocator := test_support.external_lifetime_allocator(&external)
	doc, err := toml.parse_string(
		`value = [{ dotted.child = "owned" }, [1, 2], {}]
`,
		allocator = allocator,
	)
	testing.expect(t, err == nil)
	testing.expect(t, arena.offset > 0)
	if err == nil {
		toml.destroy_document(&doc)
	}
	testing.expect(t, document_is_zero(doc))
	testing.expect_value(t, external.release_attempt_count, 0)
	testing.expect_value(t, external.free_all_count, 0)
	mem.arena_free_all(&arena)
}

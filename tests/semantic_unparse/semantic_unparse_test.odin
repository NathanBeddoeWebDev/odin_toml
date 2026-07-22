package semantic_unparse_test

import "base:runtime"
import "core:io"
import "core:mem"
import "core:reflect"
import "core:testing"
import toml "../.."
import temporal "../../temporal"
import test_support "../support"

owned_string :: proc(text: string, allocator: mem.Allocator) -> string {
	if len(text) == 0 {
		return ""
	}
	bytes, err := make([]byte, len(text), allocator)
	assert(err == nil)
	copy(bytes, transmute([]byte)text)
	return string(bytes)
}

unparse_data_diagnostic :: proc(
	t: ^testing.T,
	err: toml.Unparse_Error,
	kind: toml.Unparse_Data_Error_Kind,
) -> toml.Unparse_Diagnostic {
	diagnostic, ok := err.(toml.Unparse_Diagnostic)
	testing.expect(t, ok)
	if !ok {
		return {}
	}
	actual, detail_ok := diagnostic.detail.(toml.Unparse_Data_Error_Kind)
	testing.expect(t, detail_ok)
	if detail_ok {
		testing.expect_value(t, actual, kind)
	}
	if kind != .Invalid_Temporal {
		testing.expect_value(t, diagnostic.temporal_error, temporal.Error.None)
	}
	expect_encode_path_metadata(t, diagnostic.path)
	return diagnostic
}

expect_encode_path_metadata :: proc(t: ^testing.T, path: toml.Encode_Diagnostic_Path) {
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

unparse_limit_diagnostic :: proc(
	t: ^testing.T,
	err: toml.Unparse_Error,
	kind: toml.Unparse_Limit_Error,
) -> toml.Unparse_Diagnostic {
	diagnostic, ok := err.(toml.Unparse_Diagnostic)
	testing.expect(t, ok)
	if !ok {
		return {}
	}
	actual, detail_ok := diagnostic.detail.(toml.Unparse_Limit_Error)
	testing.expect(t, detail_ok)
	if detail_ok {
		testing.expect_value(t, actual, kind)
	}
	testing.expect_value(t, diagnostic.temporal_error, temporal.Error.None)
	expect_encode_path_metadata(t, diagnostic.path)
	return diagnostic
}

expect_path_key :: proc(
	t: ^testing.T,
	path: toml.Encode_Diagnostic_Path,
	index: int,
	expected: string,
) {
	actual, ok := path.segments[index].(string)
	testing.expect(t, ok)
	if ok {
		testing.expect_value(t, actual, expected)
	}
}

make_nested_document :: proc(depth: int, allocator: mem.Allocator) -> toml.Document {
	value := toml.Value(toml.Integer(1))
	for _ in 0..<depth {
		array, err := make(toml.Array, 1, allocator)
		assert(err == nil)
		array[0] = value
		value = toml.Value(array)
	}
	root, err := make(toml.Table, 1, allocator)
	assert(err == nil)
	root[0] = {key = owned_string("root", allocator), value = value}
	return {root = root, allocator = allocator}
}

@(test)
test_unparse_to_writer_matches_allocated_output_and_skips_empty_output :: proc(t: ^testing.T) {
	doc, parse_error := toml.parse_string(`first = "a value"
second = [{ nested = [1, 2, 3] }]
`)
	assert(parse_error == nil)
	defer toml.destroy_document(&doc)
	allocated, allocated_error := toml.unparse(&doc)
	assert(allocated_error == nil)
	defer delete(allocated)

	calls: [128]test_support.Scripted_Writer_Call
	bytes: [1024]byte
	state: test_support.Scripted_Writer
	test_support.scripted_writer_init(&state, nil, calls[:], bytes[:])
	options: toml.Marshal_Options
	err := toml.unparse_to_writer(
		test_support.scripted_writer(&state),
		&doc,
		&options,
	)
	testing.expect(t, err == nil)
	testing.expect(t, state.write_count > 1)
	testing.expect_value(t, string(bytes[:state.byte_count]), allocated)

	empty, empty_error := toml.parse_string("")
	assert(empty_error == nil)
	defer toml.destroy_document(&empty)
	empty_state: test_support.Scripted_Writer
	test_support.scripted_writer_init(&empty_state, nil, calls[:], bytes[:])
	err = toml.unparse_to_writer(
		test_support.scripted_writer(&empty_state),
		&empty,
		&options,
	)
	testing.expect(t, err == nil)
	testing.expect_value(t, empty_state.write_count, 0)
}

accepted_prefix_from_calls :: proc(
	state: ^test_support.Scripted_Writer,
	output: []byte,
) -> int {
	output_count := 0
	for call in state.calls[:min(state.call_count, len(state.calls))] {
		if call.mode != .Write || call.returned_count < 0 ||
		   call.returned_count > i64(call.requested_count) {
			continue
		}
		accepted_count := int(call.returned_count)
		requested := test_support.requested_bytes(call, state.bytes)
		assert(output_count+accepted_count <= len(output))
		copy(output[output_count:output_count+accepted_count], requested[:accepted_count])
		output_count += accepted_count
	}
	return output_count
}

run_unparse_writer_fault :: proc(
	t: ^testing.T,
	doc: ^toml.Document,
	canonical: string,
	target_ordinal: int,
	step: test_support.Scripted_Write,
	expected_error: io.Error,
) {
	steps: [256]test_support.Scripted_Write
	assert(target_ordinal <= len(steps))
	for index in 0..<target_ordinal-1 {
		steps[index] = {count_kind = .Full}
	}
	steps[target_ordinal-1] = step
	calls: [256]test_support.Scripted_Writer_Call
	requested: [4096]byte
	state: test_support.Scripted_Writer
	test_support.scripted_writer_init(
		&state,
		steps[:target_ordinal],
		calls[:],
		requested[:],
	)

	events: [256]test_support.Allocator_Event
	live: [64]test_support.Live_Allocation
	observed: test_support.Observed_Allocator
	test_support.observed_allocator_init(&observed, context.allocator, events[:], live[:])
	options: toml.Marshal_Options
	err := toml.unparse_to_writer(
		test_support.scripted_writer(&state),
		doc,
		&options,
		test_support.observed_allocator(&observed),
	)
	actual_error, ok := err.(io.Error)
	testing.expect(t, ok)
	if ok {
		testing.expect_value(t, actual_error, expected_error)
	}
	testing.expect_value(t, state.write_count, target_ordinal)
	testing.expect_value(t, state.call_count, target_ordinal)
	testing.expect_value(t, observed.live_count, 0)
	testing.expect_value(t, observed.foreign_release_count, 0)

	accepted: [4096]byte
	accepted_count := accepted_prefix_from_calls(&state, accepted[:])
	testing.expect(t, accepted_count <= len(canonical))
	if accepted_count <= len(canonical) {
		testing.expect_value(
			t,
			string(accepted[:accepted_count]),
			canonical[:accepted_count],
		)
	}
}

@(test)
test_unparse_to_writer_consumes_each_result_once_with_frozen_error_precedence :: proc(t: ^testing.T) {
	doc, parse_error := toml.parse_string(`first = "a value"
second = [{ nested = [1, 2, 3] }]
third = "last"
`)
	assert(parse_error == nil)
	defer toml.destroy_document(&doc)
	canonical, canonical_error := toml.unparse(&doc)
	assert(canonical_error == nil)
	defer delete(canonical)

	baseline_calls: [256]test_support.Scripted_Writer_Call
	baseline_bytes: [4096]byte
	baseline: test_support.Scripted_Writer
	test_support.scripted_writer_init(
		&baseline,
		nil,
		baseline_calls[:],
		baseline_bytes[:],
	)
	options: toml.Marshal_Options
	baseline_error := toml.unparse_to_writer(
		test_support.scripted_writer(&baseline),
		&doc,
		&options,
	)
	assert(baseline_error == nil)
	assert(baseline.write_count > 1)
	assert(baseline.write_count < len(baseline_calls))

	explicit_errors := [?]io.Error{
		.EOF,
		.Unexpected_EOF,
		.Short_Write,
		.Invalid_Write,
		.Short_Buffer,
		.No_Progress,
		.Invalid_Whence,
		.Invalid_Offset,
		.Invalid_Unread,
		.Negative_Read,
		.Negative_Write,
		.Negative_Count,
		.Buffer_Full,
		.Unknown,
		.No_Size,
		.Permission_Denied,
		.Closed,
		.Unsupported,
	}
	for ordinal in 1..=baseline.write_count {
		request_count := baseline.calls[ordinal-1].requested_count
		assert(request_count > 0)

		for returned_count in 0..<request_count {
			run_unparse_writer_fault(
				t,
				&doc,
				canonical,
				ordinal,
				{count_kind = .Exact, count = i64(returned_count)},
				.Short_Write,
			)
		}
		run_unparse_writer_fault(
			t,
			&doc,
			canonical,
			ordinal,
			{count_kind = .Negative},
			.Invalid_Write,
		)
		run_unparse_writer_fault(
			t,
			&doc,
			canonical,
			ordinal,
			{count_kind = .Past_End},
			.Invalid_Write,
		)

		for explicit_error in explicit_errors {
			for returned_count in 0..=request_count {
				run_unparse_writer_fault(
					t,
					&doc,
					canonical,
					ordinal,
					{
						count_kind = .Exact,
						count = i64(returned_count),
						error = explicit_error,
					},
					explicit_error,
				)
			}
			run_unparse_writer_fault(
				t,
				&doc,
				canonical,
				ordinal,
				{count_kind = .Negative, error = explicit_error},
				explicit_error,
			)
			run_unparse_writer_fault(
				t,
				&doc,
				canonical,
				ordinal,
				{count_kind = .Past_End, error = explicit_error},
				explicit_error,
			)
		}
	}
}

@(test)
test_unparse_to_writer_configuration_and_preflight_failures_make_zero_writer_calls :: proc(t: ^testing.T) {
	valid, parse_error := toml.parse_string("root = [[1]]\n")
	assert(parse_error == nil)
	defer toml.destroy_document(&valid)
	zero_doc: toml.Document
	nil_allocator: mem.Allocator
	options := toml.Marshal_Options{max_depth = -1}
	calls: [16]test_support.Scripted_Writer_Call
	bytes: [128]byte
	state: test_support.Scripted_Writer
	writer := test_support.scripted_writer(&state)

	test_support.scripted_writer_init(&state, nil, calls[:], bytes[:])
	err := toml.unparse_to_writer(writer, &zero_doc, nil, nil_allocator)
	configuration, ok := err.(toml.Unparse_Configuration_Error)
	testing.expect(t, ok)
	if ok {
		testing.expect_value(t, configuration, toml.Unparse_Configuration_Error.Invalid_Allocator)
	}
	testing.expect_value(t, state.write_count, 0)

	test_support.scripted_writer_init(&state, nil, calls[:], bytes[:])
	err = toml.unparse_to_writer(writer, &zero_doc, nil)
	configuration, ok = err.(toml.Unparse_Configuration_Error)
	testing.expect(t, ok)
	if ok {
		testing.expect_value(t, configuration, toml.Unparse_Configuration_Error.Nil_Options)
	}
	testing.expect_value(t, state.write_count, 0)

	test_support.scripted_writer_init(&state, nil, calls[:], bytes[:])
	err = toml.unparse_to_writer(writer, &zero_doc, &options)
	configuration, ok = err.(toml.Unparse_Configuration_Error)
	testing.expect(t, ok)
	if ok {
		testing.expect_value(t, configuration, toml.Unparse_Configuration_Error.Invalid_Max_Depth)
	}
	testing.expect_value(t, state.write_count, 0)

	options.max_depth = 2
	test_support.scripted_writer_init(&state, nil, calls[:], bytes[:])
	err = toml.unparse_to_writer(writer, &valid, &options)
	_ = unparse_limit_diagnostic(t, err, .Maximum_Depth_Exceeded)
	testing.expect_value(t, state.write_count, 0)

	original := valid.root[0].value
	reflect.set_union_variant_raw_tag(valid.root[0].value, 255)
	options = {}
	test_support.scripted_writer_init(&state, nil, calls[:], bytes[:])
	err = toml.unparse_to_writer(writer, &valid, &options)
	_ = unparse_data_diagnostic(t, err, .Invalid_Value_State)
	testing.expect_value(t, state.write_count, 0)
	valid.root[0].value = original

	byte_storage: byte
	raw := runtime.Raw_Dynamic_Array{
		data = &byte_storage,
		len = 0,
		cap = max(int),
		allocator = context.allocator,
	}
	overflow := toml.Document{
		root = transmute(toml.Table)raw,
		allocator = context.allocator,
	}
	test_support.scripted_writer_init(&state, nil, calls[:], bytes[:])
	err = toml.unparse_to_writer(writer, &overflow, &options)
	_ = unparse_limit_diagnostic(t, err, .Size_Overflow)
	testing.expect_value(t, state.write_count, 0)
}

@(test)
test_unparse_to_writer_cleans_every_preflight_allocation_failure_before_output :: proc(t: ^testing.T) {
	doc, parse_error := toml.parse_string(`a = "one"
b = ["two", { c = "three" }]
`)
	assert(parse_error == nil)
	defer toml.destroy_document(&doc)
	backing := context.allocator
	options: toml.Marshal_Options

	success_events: [256]test_support.Allocator_Event
	success_live: [64]test_support.Live_Allocation
	success: test_support.Observed_Allocator
	test_support.observed_allocator_init(&success, backing, success_events[:], success_live[:])
	calls: [128]test_support.Scripted_Writer_Call
	bytes: [1024]byte
	writer_state: test_support.Scripted_Writer
	test_support.scripted_writer_init(&writer_state, nil, calls[:], bytes[:])
	rejecting_success: test_support.Rejecting_Allocator
	context.allocator = test_support.rejecting_allocator(&rejecting_success)
	err := toml.unparse_to_writer(
		test_support.scripted_writer(&writer_state),
		&doc,
		&options,
		test_support.observed_allocator(&success),
	)
	context.allocator = backing
	assert(err == nil)
	assert(success.allocation_request_count > 0)
	testing.expect_value(t, rejecting_success.call_count, 0)
	testing.expect_value(t, success.live_count, 0)
	allocation_count := success.allocation_request_count

	for fail_at in 1..=allocation_count {
		events: [256]test_support.Allocator_Event
		live: [64]test_support.Live_Allocation
		observed: test_support.Observed_Allocator
		test_support.observed_allocator_init(&observed, backing, events[:], live[:])
		observed.fail_at_allocation = fail_at
		observed.failure_error = .Out_Of_Memory
		test_support.scripted_writer_init(&writer_state, nil, calls[:], bytes[:])
		rejecting: test_support.Rejecting_Allocator
		context.allocator = test_support.rejecting_allocator(&rejecting)
		err = toml.unparse_to_writer(
			test_support.scripted_writer(&writer_state),
			&doc,
			&options,
			test_support.observed_allocator(&observed),
		)
		context.allocator = backing
		allocator_error, ok := err.(runtime.Allocator_Error)
		testing.expect(t, ok)
		if ok {
			testing.expect_value(t, allocator_error, runtime.Allocator_Error.Out_Of_Memory)
		}
		testing.expect_value(t, writer_state.write_count, 0)
		testing.expect_value(t, observed.live_count, 0)
		testing.expect_value(t, observed.foreign_release_count, 0)
		testing.expect_value(t, rejecting.call_count, 0)
	}

	events: [256]test_support.Allocator_Event
	live: [64]test_support.Live_Allocation
	observed: test_support.Observed_Allocator
	test_support.observed_allocator_init(&observed, backing, events[:], live[:])
	observed.fail_at_allocation = allocation_count
	observed.failure_error = .Invalid_Argument
	test_support.scripted_writer_init(&writer_state, nil, calls[:], bytes[:])
	err = toml.unparse_to_writer(
		test_support.scripted_writer(&writer_state),
		&doc,
		&options,
		test_support.observed_allocator(&observed),
	)
	allocator_error, ok := err.(runtime.Allocator_Error)
	testing.expect(t, ok)
	if ok {
		testing.expect_value(t, allocator_error, runtime.Allocator_Error.Invalid_Argument)
	}
	testing.expect_value(t, writer_state.write_count, 0)
	testing.expect_value(t, observed.live_count, 0)
}

@(test)
test_unparse_to_writer_cleans_external_lifetime_scratch_after_io_failure :: proc(t: ^testing.T) {
	doc, parse_error := toml.parse_string(`a = "one"
b = ["two", { c = "three" }]
`)
	assert(parse_error == nil)
	defer toml.destroy_document(&doc)
	options: toml.Marshal_Options

	reporting_modes := [?]bool{true, false}
	for report_features in reporting_modes {
		buffer: [64*1024]byte
		arena: mem.Arena
		mem.arena_init(&arena, buffer[:])
		external: test_support.External_Lifetime_Allocator
		test_support.external_lifetime_allocator_init(
			&external,
			mem.arena_allocator(&arena),
			report_features,
		)
		steps := [?]test_support.Scripted_Write{{
			count_kind = .Exact,
			count = 1,
			error = .Permission_Denied,
		}}
		calls: [16]test_support.Scripted_Writer_Call
		bytes: [128]byte
		state: test_support.Scripted_Writer
		test_support.scripted_writer_init(&state, steps[:], calls[:], bytes[:])
		err := toml.unparse_to_writer(
			test_support.scripted_writer(&state),
			&doc,
			&options,
			test_support.external_lifetime_allocator(&external),
		)
		writer_error, ok := err.(io.Error)
		testing.expect(t, ok)
		if ok {
			testing.expect_value(t, writer_error, io.Error.Permission_Denied)
		}
		testing.expect_value(t, state.write_count, 1)
		testing.expect(t, external.allocation_request_count > 0)
		if report_features {
			testing.expect_value(t, external.release_attempt_count, 0)
		} else {
			testing.expect_value(t, external.release_attempt_count, 1)
		}
		mem.arena_free_all(&arena)
	}
}

@(test)
test_unparse_empty_document_returns_nil_backed_output :: proc(t: ^testing.T) {
	backing := context.allocator
	doc, parse_error := toml.parse_string("")
	testing.expect(t, parse_error == nil)
	defer toml.destroy_document(&doc)

	events: [8]test_support.Allocator_Event
	live: [1]test_support.Live_Allocation
	observed: test_support.Observed_Allocator
	test_support.observed_allocator_init(&observed, backing, events[:], live[:])
	rejecting: test_support.Rejecting_Allocator
	context.allocator = test_support.rejecting_allocator(&rejecting)
	output, err := toml.unparse(
		&doc,
		allocator = test_support.observed_allocator(&observed),
	)
	context.allocator = backing

	testing.expect(t, err == nil)
	testing.expect_value(t, len(output), 0)
	testing.expect(t, raw_data(output) == nil)
	testing.expect_value(t, observed.allocation_request_count, 0)
	testing.expect_value(t, observed.live_count, 0)
	testing.expect_value(t, rejecting.call_count, 0)

	retained, retained_parse_error := toml.parse_string("removed = 1\n")
	assert(retained_parse_error == nil)
	defer toml.destroy_document(&retained)
	testing.expect(t, toml.remove(&retained.root, "removed"))
	testing.expect_value(t, len(retained.root), 0)
	testing.expect(t, cap(retained.root) > 0)
	retained_output, retained_error := toml.unparse(
		&retained,
		allocator = test_support.observed_allocator(&observed),
	)
	testing.expect(t, retained_error == nil)
	testing.expect(t, raw_data(retained_output) == nil)
	testing.expect_value(t, observed.allocation_request_count, 0)
	testing.expect_value(t, observed.live_count, 0)
}

@(test)
test_unparse_uses_the_public_canonical_document_profile :: proc(t: ^testing.T) {
	doc, parse_error := toml.parse_string(`bare = "value"
"a.b" = [1, { z = true, a = false }, []]
`)
	testing.expect(t, parse_error == nil)
	if parse_error != nil {
		return
	}
	defer toml.destroy_document(&doc)

	output, err := toml.unparse(&doc)
	testing.expect(t, err == nil)
	if err != nil {
		return
	}
	defer delete(output)
	testing.expect_value(
		t,
		output,
		`"bare" = "value"
"a.b" = [1, { "z" = true, "a" = false }, []]
`,
	)
}

@(test)
test_unparse_canonicalizes_text_integer_boolean_and_temporal_spellings :: proc(t: ^testing.T) {
	source := `"control\u0001" = "quote: \" slash: \\ controls: \b\t\n\f\r\e\x00\x01\x1f\x7f unicode: α"
minimum = -9223372036854775808
truth = true
falsehood = false
offset_unknown = 1979-05-27t07:32:00.1234567899-00:00
offset_utc = 1979-05-27 07:32z
offset_negative = 1979-05-27T07:32:00-05:30
local_datetime = 0000-02-29 23:59:60.120000000
local_date = 9999-12-31
local_time = 07:32
`
	doc, parse_error := toml.parse_string(source)
	testing.expect(t, parse_error == nil)
	if parse_error != nil {
		return
	}
	defer toml.destroy_document(&doc)

	output, err := toml.unparse(&doc)
	testing.expect(t, err == nil)
	if err != nil {
		return
	}
	defer delete(output)
	expected := `"control\x01" = "quote: \" slash: \\ controls: \b\t\n\f\r\e\x00\x01\x1F\x7F unicode: α"
"minimum" = -9223372036854775808
"truth" = true
"falsehood" = false
"offset_unknown" = 1979-05-27T07:32:00.123456789-00:00
"offset_utc" = 1979-05-27T07:32:00Z
"offset_negative" = 1979-05-27T07:32:00-05:30
"local_datetime" = 0000-02-29T23:59:60.12
"local_date" = 9999-12-31
"local_time" = 07:32:00
`
	testing.expect_value(t, output, expected)

	reparsed, reparse_error := toml.parse_string(output)
	testing.expect(t, reparse_error == nil)
	if reparse_error != nil {
		return
	}
	defer toml.destroy_document(&reparsed)
	testing.expect(t, test_support.semantic_table_equal(doc.root, reparsed.root))
	reencoded, reencode_error := toml.unparse(&reparsed)
	testing.expect(t, reencode_error == nil)
	if reencode_error != nil {
		return
	}
	defer delete(reencoded)
	testing.expect_value(t, reencoded, expected)
}

@(test)
test_unparse_float_oracle_vectors_are_exact_and_repeatable_through_public_seam :: proc(t: ^testing.T) {
	cases := [?]struct {
		key:  string,
		bits: u64,
	}{
		{"positive_zero", 0x0000_0000_0000_0000},
		{"negative_zero", 0x8000_0000_0000_0000},
		{"positive_inf", 0x7ff0_0000_0000_0000},
		{"negative_inf", 0xfff0_0000_0000_0000},
		{"nan_payload", 0xfff8_0000_0000_0001},
		{"minimum_subnormal", 0x0000_0000_0000_0001},
		{"maximum_finite", 0x7fef_ffff_ffff_ffff},
		{"integer_looking", 0x4340_0000_0000_0000},
		{"scientific_shorter", 0x412e_8480_0000_0000},
		{"closest_even_tie", 0x4305_edd4_5e85_c45a},
	}
	doc, parse_error := toml.parse_string("")
	assert(parse_error == nil)
	defer toml.destroy_document(&doc)
	for test_case in cases {
		value := toml.Value(toml.Float(transmute(f64)test_case.bits))
		set_error := toml.set(&doc.root, test_case.key, &value)
		testing.expect(t, set_error == nil)
	}

	expected := `"positive_zero" = 0.0
"negative_zero" = -0.0
"positive_inf" = inf
"negative_inf" = -inf
"nan_payload" = nan
"minimum_subnormal" = 5e-324
"maximum_finite" = 1.7976931348623157e308
"integer_looking" = 9007199254740992.0
"scientific_shorter" = 1e6
"closest_even_tie" = 771558860699787.2
`
	first, first_error := toml.unparse(&doc)
	testing.expect(t, first_error == nil)
	if first_error != nil {
		return
	}
	defer delete(first)
	second, second_error := toml.unparse(&doc)
	testing.expect(t, second_error == nil)
	if second_error != nil {
		return
	}
	defer delete(second)
	testing.expect_value(t, first, expected)
	testing.expect_value(t, second, expected)

	reparsed, reparse_error := toml.parse_string(first)
	testing.expect(t, reparse_error == nil)
	if reparse_error != nil {
		return
	}
	defer toml.destroy_document(&reparsed)
	testing.expect(t, test_support.semantic_table_equal(doc.root, reparsed.root))
	reencoded, reencode_error := toml.unparse(&reparsed)
	testing.expect(t, reencode_error == nil)
	if reencode_error != nil {
		return
	}
	defer delete(reencoded)
	testing.expect_value(t, reencoded, expected)
}

@(test)
test_unparse_all_temporal_value_alternatives_can_be_constructed_semantically :: proc(t: ^testing.T) {
	doc, parse_error := toml.parse_string("")
	assert(parse_error == nil)
	defer toml.destroy_document(&doc)
	values := [?]struct {
		key:   string,
		value: toml.Value,
	}{
		{"offset", toml.Value(temporal.Offset_Date_Time{
			local = {date = {2026, 7, 21}, time = {12, 34, 56, 789_000_000}},
			offset = {.Known, 90},
		})},
		{"datetime", toml.Value(temporal.Local_Date_Time{
			date = {2024, 2, 29},
			time = {23, 59, 60, 999_999_999},
		})},
		{"date", toml.Value(temporal.Local_Date{0, 1, 1})},
		{"time", toml.Value(temporal.Local_Time{0, 0, 0, 1})},
	}
	for &item in values {
		assert(toml.set(&doc.root, item.key, &item.value) == nil)
	}

	output, err := toml.unparse(&doc)
	testing.expect(t, err == nil)
	if err != nil {
		return
	}
	defer delete(output)
	testing.expect_value(t, output, `"offset" = 2026-07-21T12:34:56.789+01:30
"datetime" = 2024-02-29T23:59:60.999999999
"date" = 0000-01-01
"time" = 00:00:00.000000001
`)
}

@(test)
test_unparse_configuration_precedence_and_zero_document_errors_return_empty_output :: proc(t: ^testing.T) {
	valid, parse_error := toml.parse_string("a = 1\n")
	assert(parse_error == nil)
	defer toml.destroy_document(&valid)
	zero_doc: toml.Document
	nil_allocator: mem.Allocator

	output, err := toml.unparse(&zero_doc, {max_depth = -1}, nil_allocator)
	testing.expect(t, raw_data(output) == nil)
	configuration, ok := err.(toml.Unparse_Configuration_Error)
	testing.expect(t, ok)
	if ok {
		testing.expect_value(t, configuration, toml.Unparse_Configuration_Error.Invalid_Allocator)
	}

	invalid_depths := [?]int{-1, 257}
	for invalid_depth in invalid_depths {
		output, err = toml.unparse(&zero_doc, {max_depth = invalid_depth})
		testing.expect(t, raw_data(output) == nil)
		configuration, ok = err.(toml.Unparse_Configuration_Error)
		testing.expect(t, ok)
		if ok {
			testing.expect_value(t, configuration, toml.Unparse_Configuration_Error.Invalid_Max_Depth)
		}
	}

	output, err = toml.unparse(nil)
	testing.expect(t, raw_data(output) == nil)
	_ = unparse_data_diagnostic(t, err, .Invalid_Document)
	output, err = toml.unparse(&zero_doc)
	testing.expect(t, raw_data(output) == nil)
	_ = unparse_data_diagnostic(t, err, .Invalid_Document)
}

@(test)
test_unparse_reports_invalid_union_text_duplicate_and_temporal_at_canonical_paths :: proc(t: ^testing.T) {
	doc, parse_error := toml.parse_string("first = 1\nsecond = \"owned\"\n")
	assert(parse_error == nil)
	defer toml.destroy_document(&doc)

	original_first := doc.root[0].value
	reflect.set_union_variant_raw_tag(doc.root[0].value, 255)
	output, err := toml.unparse(&doc)
	testing.expect(t, raw_data(output) == nil)
	diagnostic := unparse_data_diagnostic(t, err, .Invalid_Value_State)
	expect_path_key(t, diagnostic.path, 0, "first")
	doc.root[0].value = original_first

	original_key := doc.root[0].key
	invalid_bytes := [1]byte{0xff}
	doc.root[0].key = string(invalid_bytes[:])
	output, err = toml.unparse(&doc)
	testing.expect(t, raw_data(output) == nil)
	diagnostic = unparse_data_diagnostic(t, err, .Invalid_Text)
	expect_path_key(t, diagnostic.path, 0, doc.root[0].key)
	doc.root[0].key = original_key

	original_second := doc.root[1].value
	doc.root[1].value = toml.Value(toml.String(string(invalid_bytes[:])))
	output, err = toml.unparse(&doc)
	testing.expect(t, raw_data(output) == nil)
	diagnostic = unparse_data_diagnostic(t, err, .Invalid_Text)
	expect_path_key(t, diagnostic.path, 0, "second")
	doc.root[1].value = original_second

	original_second_key := doc.root[1].key
	doc.root[1].key = doc.root[0].key
	output, err = toml.unparse(&doc)
	testing.expect(t, raw_data(output) == nil)
	diagnostic = unparse_data_diagnostic(t, err, .Duplicate_Key)
	expect_path_key(t, diagnostic.path, 0, "first")
	doc.root[1].key = original_second_key

	doc.root[0].value = toml.Value(temporal.Local_Date{2024, 2, 30})
	output, err = toml.unparse(&doc)
	testing.expect(t, raw_data(output) == nil)
	diagnostic = unparse_data_diagnostic(t, err, .Invalid_Temporal)
	testing.expect_value(t, diagnostic.temporal_error, temporal.Error.Invalid_Day)
	expect_path_key(t, diagnostic.path, 0, "first")
	doc.root[0].value = original_first
}

@(test)
test_unparse_preflight_rejects_container_cycle_alias_and_allocator_mismatch :: proc(t: ^testing.T) {
	buffer: [32*1024]byte
	arena: mem.Arena
	mem.arena_init(&arena, buffer[:])
	allocator := mem.arena_allocator(&arena)
	root, root_error := make(toml.Table, 1, allocator)
	assert(root_error == nil)
	root[0].key = owned_string("root", allocator)
	doc := toml.Document{root = root, allocator = allocator}

	uninitialized: toml.Array
	root[0].value = toml.Value(uninitialized)
	output, err := toml.unparse(&doc)
	testing.expect(t, raw_data(output) == nil)
	diagnostic := unparse_data_diagnostic(t, err, .Invalid_Container)
	expect_path_key(t, diagnostic.path, 0, "root")

	cycle, cycle_error := make(toml.Array, 1, allocator)
	assert(cycle_error == nil)
	cycle[0] = toml.Value(cycle)
	root[0].value = toml.Value(cycle)
	output, err = toml.unparse(&doc)
	testing.expect(t, raw_data(output) == nil)
	diagnostic = unparse_data_diagnostic(t, err, .Cycle)
	expect_path_key(t, diagnostic.path, 0, "root")
	index, index_ok := diagnostic.path.segments[1].(toml.Path_Index)
	testing.expect(t, index_ok)
	if index_ok {
		testing.expect_value(t, index, toml.Path_Index(0))
	}

	shared := owned_string("shared", allocator)
	aliases, aliases_error := make(toml.Array, 2, allocator)
	assert(aliases_error == nil)
	aliases[0] = toml.Value(toml.String(shared))
	aliases[1] = toml.Value(toml.String(shared))
	root[0].value = toml.Value(aliases)
	output, err = toml.unparse(&doc)
	testing.expect(t, raw_data(output) == nil)
	diagnostic = unparse_data_diagnostic(t, err, .Ownership_Alias)
	expect_path_key(t, diagnostic.path, 0, "root")

	other_buffer: [1024]byte
	other_arena: mem.Arena
	mem.arena_init(&other_arena, other_buffer[:])
	other_allocator := mem.arena_allocator(&other_arena)
	mismatched, mismatch_error := make(toml.Array, other_allocator)
	assert(mismatch_error == nil)
	root[0].value = toml.Value(mismatched)
	output, err = toml.unparse(&doc)
	testing.expect(t, raw_data(output) == nil)
	diagnostic = unparse_data_diagnostic(t, err, .Allocator_Mismatch)
	expect_path_key(t, diagnostic.path, 0, "root")
}

@(test)
test_unparse_depth_limits_include_prospective_key_and_array_index :: proc(t: ^testing.T) {
	doc, parse_error := toml.parse_string("root = [[1]]\n")
	assert(parse_error == nil)
	defer toml.destroy_document(&doc)

	output, err := toml.unparse(&doc, {max_depth = 2})
	testing.expect(t, raw_data(output) == nil)
	diagnostic := unparse_limit_diagnostic(t, err, .Maximum_Depth_Exceeded)
	testing.expect_value(t, diagnostic.path.total_segment_count, u16(3))
	expect_path_key(t, diagnostic.path, 0, "root")
	for segment_index in 1..=2 {
		index, ok := diagnostic.path.segments[segment_index].(toml.Path_Index)
		testing.expect(t, ok)
		if ok {
			testing.expect_value(t, index, toml.Path_Index(0))
		}
	}

	output, err = toml.unparse(&doc, {max_depth = 3})
	testing.expect(t, err == nil)
	if err != nil {
		return
	}
	defer delete(output)
	testing.expect_value(t, output, `"root" = [[1]]
`)
}

@(test)
test_unparse_default_and_hard_depth_boundaries_are_exact :: proc(t: ^testing.T) {
	buffer: [256*1024]byte
	arena: mem.Arena
	mem.arena_init(&arena, buffer[:])
	allocator := mem.arena_allocator(&arena)

	default_valid := make_nested_document(127, allocator)
	output, err := toml.unparse(&default_valid)
	testing.expect(t, err == nil)
	if err == nil {
		delete(output)
	}
	default_invalid := make_nested_document(128, allocator)
	output, err = toml.unparse(&default_invalid)
	testing.expect(t, raw_data(output) == nil)
	_ = unparse_limit_diagnostic(t, err, .Maximum_Depth_Exceeded)

	hard_valid := make_nested_document(255, allocator)
	output, err = toml.unparse(&hard_valid, {max_depth = 256})
	testing.expect(t, err == nil)
	if err == nil {
		delete(output)
	}
	hard_invalid := make_nested_document(256, allocator)
	output, err = toml.unparse(&hard_invalid, {max_depth = 256})
	testing.expect(t, raw_data(output) == nil)
	diagnostic := unparse_limit_diagnostic(t, err, .Maximum_Depth_Exceeded)
	testing.expect_value(t, diagnostic.path.total_segment_count, u16(257))
	testing.expect(t, diagnostic.path.truncated)
	testing.expect_value(t, diagnostic.path.omitted_segment_count, u16(225))
}

@(test)
test_unparse_rejects_checked_container_size_overflow_before_output_allocation :: proc(t: ^testing.T) {
	byte_storage: byte
	raw := runtime.Raw_Dynamic_Array{
		data = &byte_storage,
		len = 0,
		cap = max(int),
		allocator = context.allocator,
	}
	doc := toml.Document{
		root = transmute(toml.Table)raw,
		allocator = context.allocator,
	}
	output, err := toml.unparse(&doc)
	testing.expect(t, raw_data(output) == nil)
	_ = unparse_limit_diagnostic(t, err, .Size_Overflow)
}

@(test)
test_unparse_supports_both_external_lifetime_allocator_release_branches :: proc(t: ^testing.T) {
	doc, parse_error := toml.parse_string(`a = "one"
b = "two"
c = ["three", { d = "four" }]
`)
	assert(parse_error == nil)
	defer toml.destroy_document(&doc)

	reporting_modes := [?]bool{true, false}
	for report_features in reporting_modes {
		buffer: [64*1024]byte
		arena: mem.Arena
		mem.arena_init(&arena, buffer[:])
		external: test_support.External_Lifetime_Allocator
		test_support.external_lifetime_allocator_init(
			&external,
			mem.arena_allocator(&arena),
			report_features,
		)
		allocator := test_support.external_lifetime_allocator(&external)
		output, err := toml.unparse(&doc, allocator = allocator)
		testing.expect(t, err == nil)
		if err != nil {
			continue
		}
		testing.expect_value(t, output, `"a" = "one"
"b" = "two"
"c" = ["three", { "d" = "four" }]
`)
		testing.expect(t, external.allocation_request_count > 0)
		if report_features {
			testing.expect_value(t, external.release_attempt_count, 0)
		} else {
			testing.expect_value(t, external.release_attempt_count, 1)
		}
		// The returned owner and logically released scratch share the external
		// lifetime. Reclaim them together rather than individually deleting output.
		output = ""
		mem.arena_free_all(&arena)
	}
}

@(test)
test_unparse_allocates_only_exact_result_and_cleans_every_failed_ordinal :: proc(t: ^testing.T) {
	doc, parse_error := toml.parse_string(`first = "a value"
second = [{ nested = [1, 2, 3] }]
`)
	assert(parse_error == nil)
	defer toml.destroy_document(&doc)
	backing := context.allocator

	success_events: [256]test_support.Allocator_Event
	success_live: [64]test_support.Live_Allocation
	success_state: test_support.Observed_Allocator
	test_support.observed_allocator_init(
		&success_state,
		backing,
		success_events[:],
		success_live[:],
	)
	selected := test_support.observed_allocator(&success_state)
	rejecting: test_support.Rejecting_Allocator
	context.allocator = test_support.rejecting_allocator(&rejecting)
	output, success_error := toml.unparse(&doc, allocator = selected)
	context.allocator = backing
	testing.expect(t, success_error == nil)
	if success_error != nil {
		return
	}
	testing.expect_value(t, success_state.live_count, 1)
	if success_state.live_count == 1 {
		testing.expect_value(t, success_state.live[0].memory, rawptr(raw_data(output)))
		testing.expect_value(t, success_state.live[0].size, len(output))
	}
	testing.expect_value(t, rejecting.call_count, 0)
	allocation_count := success_state.allocation_request_count
	delete(output, selected)
	testing.expect_value(t, success_state.live_count, 0)

	for fail_at in 1..=allocation_count {
		events: [256]test_support.Allocator_Event
		live: [64]test_support.Live_Allocation
		state: test_support.Observed_Allocator
		test_support.observed_allocator_init(&state, backing, events[:], live[:])
		state.fail_at_allocation = fail_at
		state.failure_error = .Out_Of_Memory
		failing_allocator := test_support.observed_allocator(&state)
		failed_output, err := toml.unparse(&doc, allocator = failing_allocator)
		testing.expect(t, raw_data(failed_output) == nil)
		allocator_error, ok := err.(runtime.Allocator_Error)
		testing.expect(t, ok)
		if ok {
			testing.expect_value(t, allocator_error, runtime.Allocator_Error.Out_Of_Memory)
		}
		testing.expect_value(t, state.live_count, 0)
		testing.expect_value(t, state.foreign_release_count, 0)
	}

	events: [256]test_support.Allocator_Event
	live: [64]test_support.Live_Allocation
	state: test_support.Observed_Allocator
	test_support.observed_allocator_init(&state, backing, events[:], live[:])
	state.fail_at_allocation = allocation_count
	state.failure_error = .Invalid_Argument
	failed_output, err := toml.unparse(
		&doc,
		allocator = test_support.observed_allocator(&state),
	)
	testing.expect(t, raw_data(failed_output) == nil)
	allocator_error, ok := err.(runtime.Allocator_Error)
	testing.expect(t, ok)
	if ok {
		testing.expect_value(t, allocator_error, runtime.Allocator_Error.Invalid_Argument)
	}
	testing.expect_value(t, state.live_count, 0)
}

package typed_fuzz_test

import "base:runtime"
import "core:io"
import "core:mem"
import "core:strings"
import toml "../.."
import temporal "../../vendor/temporal"
import test_support "../support"

Property_Codec :: distinct u8

Property_Optional :: union {
	Property_Leaf,
}

Property_Leaf :: struct {
	text:   string,
	number: i32,
}

Property_Root :: struct {
	// The exact codec is first so its unmarshal callback marks the first
	// installation commit after the complete immutable preflight.
	codec:         Property_Codec,
	renamed:       i32 `toml:"represented"`,
	defaulted:     i32 `toml:",omitempty"`,
	missing_owned: string `toml:",omitempty"`,
	ignored:       string `toml:"-"`,
	fixed:         [3]i16,
	slice:         []string,
	dynamic_values: [dynamic]u16,
	mapping:       map[string]Property_Codec,
	pointer:       ^Property_Leaf,
	optional:      Property_Optional,
	date:          temporal.Local_Date,
}

Any_Root :: struct {
	payload: any,
}

Cycle_Node :: struct {
	value: i32,
	next:  ^Cycle_Node `toml:",omitempty"`,
}

Cycle_Root :: struct {
	codec: Property_Codec,
	node:  ^Cycle_Node,
}

Failing_Codec :: struct {
	dirty: i32,
}

Transaction_Root :: struct {
	first:   string,
	failing: Failing_Codec,
}

Codec_State :: struct {
	marshal_values:   [16]Property_Codec,
	unmarshal_values: [16]Property_Codec,
	marshal_count:    int,
	unmarshal_count:  int,
	failure_code:     u32,
}

CODEC_TEXTS := [?]string{
	"codec-zero",
	"codec-one",
	"codec-two",
	"codec-three",
	"codec-four",
	"codec-five",
	"codec-six",
	"codec-seven",
}

TEXT_VALUES := [?]string{"", "plain", "alpha-α", "feather-🪶", "line\nbreak"}
MAP_KEYS := [?]string{"zeta", "alpha", "middle"}

input_byte :: proc(input: []byte, index: int) -> byte {
	if len(input) == 0 {
		return byte(index*53+17)
	}
	return input[index%len(input)]
}

random_from_input :: proc(input: []byte) -> test_support.Replay_Random {
	seed: u64 = 0xcbf29ce484222325
	for value in input {
		seed = (seed ~ u64(value))*0x100000001b3
	}
	return test_support.replay_random_init(seed)
}

codec_index :: proc(value: Property_Codec) -> int {
	return int(value)%len(CODEC_TEXTS)
}

marshal_property_codec :: proc(
	source: any,
	user_data: rawptr,
	allocator: mem.Allocator,
	loc: runtime.Source_Code_Location,
) -> (toml.Value, toml.Codec_Callback_Error) {
	_ = loc
	state := (^Codec_State)(user_data)
	assert(source.id == typeid_of(Property_Codec))
	value := (^Property_Codec)(source.data)^
	assert(state.marshal_count < len(state.marshal_values))
	state.marshal_values[state.marshal_count] = value
	state.marshal_count += 1
	owned, err := strings.clone(CODEC_TEXTS[codec_index(value)], allocator)
	if err != nil {
		return {}, err
	}
	return toml.Value(toml.String(owned)), nil
}

unmarshal_property_codec :: proc(
	source: ^toml.Value,
	destination: any,
	user_data: rawptr,
	allocator: mem.Allocator,
	loc: runtime.Source_Code_Location,
) -> toml.Codec_Callback_Error {
	_, _ = allocator, loc
	state := (^Codec_State)(user_data)
	assert(source != nil && destination.id == typeid_of(Property_Codec))
	text, ok := source^.(toml.String)
	if !ok {
		return toml.Codec_Callback_Failure{code = 71}
	}
	for candidate, index in CODEC_TEXTS {
		if string(text) == candidate {
			value := Property_Codec(index)
			assert(state.unmarshal_count < len(state.unmarshal_values))
			state.unmarshal_values[state.unmarshal_count] = value
			state.unmarshal_count += 1
			(^Property_Codec)(destination.data)^ = value
			return nil
		}
	}
	return toml.Codec_Callback_Failure{code = 72}
}

unmarshal_failing_codec :: proc(
	source: ^toml.Value,
	destination: any,
	user_data: rawptr,
	allocator: mem.Allocator,
	loc: runtime.Source_Code_Location,
) -> toml.Codec_Callback_Error {
	_, _, _ = source, allocator, loc
	state := (^Codec_State)(user_data)
	(^Failing_Codec)(destination.data)^ = {dirty = 0x1234}
	return toml.Codec_Callback_Failure{code = state.failure_code}
}

init_property_registry :: proc(state: ^Codec_State) -> toml.Codec_Registry {
	registry, err := toml.init_codec_registry()
	assert(err == nil)
	assert(toml.register_marshaler(
		&registry,
		typeid_of(Property_Codec),
		{procedure = marshal_property_codec, user_data = state},
	) == nil)
	assert(toml.register_unmarshaler(
		&registry,
		typeid_of(Property_Codec),
		{procedure = unmarshal_property_codec, user_data = state},
	) == nil)
	return registry
}

make_property_source :: proc(
	random: ^test_support.Replay_Random,
	leaf: ^Property_Leaf,
) -> Property_Root {
	root: Property_Root
	root.renamed = i32(test_support.replay_int_max(random, 2001)-1000)
	root.defaulted = 0
	root.ignored = "source-ignored"
	for &value in root.fixed {
		value = i16(test_support.replay_int_max(random, 2001)-1000)
	}
	slice_count := test_support.replay_int_max(random, 4)
	root.slice = make([]string, slice_count)
	for &value in root.slice {
		value = TEXT_VALUES[test_support.replay_int_max(random, len(TEXT_VALUES))]
	}
	root.dynamic_values = make([dynamic]u16)
	for _ in 0..<test_support.replay_int_max(random, 4) {
		append(&root.dynamic_values, u16(test_support.replay_int_max(random, 65_536)))
	}
	root.mapping = make(map[string]Property_Codec)
	start := test_support.replay_int_max(random, len(MAP_KEYS))
	for offset in 0..<len(MAP_KEYS) {
		index := (start+offset)%len(MAP_KEYS)
		root.mapping[MAP_KEYS[index]] = Property_Codec(
			test_support.replay_int_max(random, len(CODEC_TEXTS)),
		)
	}
	leaf^ = {
		text = TEXT_VALUES[test_support.replay_int_max(random, len(TEXT_VALUES))],
		number = i32(test_support.replay_int_max(random, 2001)-1000),
	}
	root.pointer = leaf
	root.optional = Property_Leaf{
		text = TEXT_VALUES[test_support.replay_int_max(random, len(TEXT_VALUES))],
		number = i32(test_support.replay_int_max(random, 2001)-1000),
	}
	root.codec = Property_Codec(test_support.replay_int_max(random, len(CODEC_TEXTS)))
	root.date = {2024, u8(1+test_support.replay_int_max(random, 12)), 1}
	return root
}

cleanup_property_source :: proc(root: ^Property_Root) {
	if raw_data(root.slice) != nil {
		assert(delete(root.slice) == nil)
	}
	root.slice = nil
	if root.dynamic_values.allocator.procedure != nil {
		assert(delete(root.dynamic_values) == nil)
	}
	root.dynamic_values = nil
	if root.mapping.allocator.procedure != nil {
		assert(delete(root.mapping) == nil)
	}
	root.mapping = nil
	root.pointer = nil
	root.optional = nil
}

cleanup_property_destination :: proc(root: ^Property_Root, allocator: mem.Allocator) {
	for &value in root.slice {
		if len(value) > 0 {
			assert(delete(value, allocator) == nil)
		}
		value = ""
	}
	if raw_data(root.slice) != nil {
		assert(delete(root.slice, allocator) == nil)
	}
	root.slice = nil
	if root.dynamic_values.allocator.procedure != nil {
		assert(delete(root.dynamic_values) == nil)
	}
	root.dynamic_values = nil
	for key in root.mapping {
		assert(delete(key, allocator) == nil)
	}
	if root.mapping.allocator.procedure != nil {
		assert(delete(root.mapping) == nil)
	}
	root.mapping = nil
	if root.pointer != nil {
		if len(root.pointer.text) > 0 {
			assert(delete(root.pointer.text, allocator) == nil)
		}
		root.pointer.text = ""
		assert(free(root.pointer, allocator) == nil)
		root.pointer = nil
	}
	if optional, ok := root.optional.(Property_Leaf); ok {
		if len(optional.text) > 0 {
			assert(delete(optional.text, allocator) == nil)
		}
	}
	root.optional = nil
}

property_values_equal :: proc(actual, expected: ^Property_Root) -> bool {
	if actual.renamed != expected.renamed || actual.fixed != expected.fixed ||
	   actual.codec != expected.codec || actual.date != expected.date ||
	   len(actual.dynamic_values) != len(expected.dynamic_values) ||
	   len(actual.slice) != len(expected.slice) ||
	   len(actual.mapping) != len(expected.mapping) || actual.pointer == nil {
		return false
	}
	for value, index in actual.dynamic_values {
		if value != expected.dynamic_values[index] {
			return false
		}
	}
	for value, index in actual.slice {
		if value != expected.slice[index] {
			return false
		}
	}
	for key, expected_value in expected.mapping {
		if actual_value, ok := actual.mapping[key]; !ok || actual_value != expected_value {
			return false
		}
	}
	if actual.pointer.text != expected.pointer.text ||
	   actual.pointer.number != expected.pointer.number {
		return false
	}
	actual_optional, actual_ok := actual.optional.(Property_Leaf)
	expected_optional, expected_ok := expected.optional.(Property_Leaf)
	return actual_ok && expected_ok && actual_optional == expected_optional
}

expected_codec_order :: proc(source: ^Property_Root) -> [4]Property_Codec {
	return {
		source.codec,
		source.mapping["alpha"],
		source.mapping["middle"],
		source.mapping["zeta"],
	}
}

assert_allocator_clean :: proc(observed: ^test_support.Observed_Allocator) {
	assert(observed.live_count == 0)
	assert(observed.foreign_release_count == 0)
	assert(observed.foreign_resize_count == 0)
	assert(observed.live_overflow_count == 0)
	assert(observed.dropped_event_count == 0)
}

run_round_trip_case :: proc(input: []byte) {
	random := random_from_input(input)
	leaf: Property_Leaf
	source := make_property_source(&random, &leaf)
	defer cleanup_property_source(&source)
	state: Codec_State
	registry := init_property_registry(&state)
	defer toml.destroy_codec_registry(&registry)

	events: [2048]test_support.Allocator_Event
	live: [512]test_support.Live_Allocation
	observed: test_support.Observed_Allocator
	test_support.observed_allocator_init(&observed, context.allocator, events[:], live[:])
	selected := test_support.observed_allocator(&observed)
	bytes, marshal_error := toml.marshal(source, {codecs = &registry}, selected)
	assert(marshal_error == nil)
	assert(raw_data(bytes) != nil)

	application_events: [64]test_support.Allocator_Event
	application_live: [32]test_support.Live_Allocation
	application_observed: test_support.Observed_Allocator
	test_support.observed_allocator_init(
		&application_observed,
		context.allocator,
		application_events[:],
		application_live[:],
	)
	application_allocator := test_support.observed_allocator(&application_observed)
	application_default, default_error := strings.clone(
		"application-default",
		application_allocator,
	)
	assert(default_error == nil)
	destination := Property_Root{
		defaulted = 777,
		missing_owned = application_default,
		ignored = "destination-ignored",
	}
	unmarshal_error := toml.unmarshal(
		bytes,
		&destination,
		{codecs = &registry},
		selected,
	)
	assert(unmarshal_error == nil)
	assert(property_values_equal(&destination, &source))
	assert(destination.defaulted == 777)
	assert(destination.missing_owned == "application-default")
	assert(raw_data(destination.missing_owned) == raw_data(application_default))
	assert(destination.ignored == "destination-ignored")
	expected := expected_codec_order(&source)
	assert(state.marshal_count == len(expected))
	assert(state.unmarshal_count == len(expected))
	for value, index in expected {
		assert(state.marshal_values[index] == value)
		assert(state.unmarshal_values[index] == value)
	}

	second, second_error := toml.marshal(source, {codecs = &registry}, selected)
	assert(second_error == nil && string(second) == string(bytes))
	assert(state.marshal_count == 2*len(expected))
	assert(delete(second, selected) == nil)
	cleanup_property_destination(&destination, selected)
	assert(delete(destination.missing_owned, application_allocator) == nil)
	destination.missing_owned = ""
	assert(delete(bytes, selected) == nil)
	assert_allocator_clean(&observed)
	assert_allocator_clean(&application_observed)
}

run_unknown_preflight_case :: proc() {
	destination := Property_Root{
		renamed = 91,
		defaulted = 777,
		missing_owned = "application-default",
		ignored = "application-owned",
		fixed = {1, 2, 3},
	}
	before := destination
	err := toml.unmarshal_string(
		"represented = 1\nunknown = 2\n",
		&destination,
		{reject_unknown_fields = true},
	)
	diagnostic, ok := err.(toml.Unmarshal_Diagnostic)
	assert(ok)
	data, data_ok := diagnostic.detail.(toml.Unmarshal_Data_Error)
	assert(data_ok && data.kind == .Unknown_Field)
	assert(destination.renamed == before.renamed)
	assert(destination.defaulted == before.defaulted)
	assert(destination.missing_owned == before.missing_owned)
	assert(destination.ignored == before.ignored)
	assert(destination.fixed == before.fixed)
	assert(raw_data(destination.slice) == nil)
	assert(destination.dynamic_values.allocator.procedure == nil)
	assert(destination.mapping.allocator.procedure == nil)
	assert(destination.pointer == nil && destination.optional == nil)
}

run_transaction_case :: proc() {
	state := Codec_State{failure_code = 0x2600_0001}
	registry, registry_error := toml.init_codec_registry()
	assert(registry_error == nil)
	defer toml.destroy_codec_registry(&registry)
	assert(toml.register_unmarshaler(
		&registry,
		typeid_of(Failing_Codec),
		{procedure = unmarshal_failing_codec, user_data = &state},
	) == nil)

	events: [256]test_support.Allocator_Event
	live: [64]test_support.Live_Allocation
	observed: test_support.Observed_Allocator
	test_support.observed_allocator_init(&observed, context.allocator, events[:], live[:])
	selected := test_support.observed_allocator(&observed)
	destination: Transaction_Root
	err := toml.unmarshal_string(
		"first = \"committed\"\nfailing = 9\n",
		&destination,
		{codecs = &registry},
		selected,
	)
	diagnostic, ok := err.(toml.Unmarshal_Diagnostic)
	assert(ok)
	codec_error, codec_ok := diagnostic.detail.(toml.Unmarshal_Codec_Error)
	assert(codec_ok && codec_error.code == state.failure_code)
	assert(destination.first == "committed")
	assert(destination.failing == {})
	assert(delete(destination.first, selected) == nil)
	destination.first = ""
	assert_allocator_clean(&observed)
}

run_active_cycle_case :: proc() {
	state: Codec_State
	registry := init_property_registry(&state)
	defer toml.destroy_codec_registry(&registry)
	node := Cycle_Node{value = 1}
	node.next = &node
	root := Cycle_Root{codec = 2, node = &node}

	events: [512]test_support.Allocator_Event
	live: [128]test_support.Live_Allocation
	observed: test_support.Observed_Allocator
	test_support.observed_allocator_init(&observed, context.allocator, events[:], live[:])
	selected := test_support.observed_allocator(&observed)
	steps: [1]test_support.Scripted_Write
	calls: [32]test_support.Scripted_Writer_Call
	requested: [1024]byte
	writer: test_support.Scripted_Writer
	test_support.scripted_writer_init(&writer, steps[:0], calls[:], requested[:])
	err := toml.marshal_to_writer(
		test_support.scripted_writer(&writer),
		root,
		&toml.Marshal_Options{codecs = &registry},
		selected,
	)
	diagnostic, ok := err.(toml.Marshal_Diagnostic)
	assert(ok)
	data, data_ok := diagnostic.detail.(toml.Marshal_Data_Error)
	assert(data_ok && data.kind == .Active_Recursion_Cycle)
	assert(writer.call_count == 0 && writer.write_count == 0)
	assert(state.marshal_count == 1)
	assert_allocator_clean(&observed)
}

run_any_case :: proc(input: []byte) {
	payload := i32(input_byte(input, 1))
	root := Any_Root{payload = payload}
	bytes, err := toml.marshal(root)
	assert(err == nil)
	defer delete(bytes)
	second, second_error := toml.marshal(root)
	assert(second_error == nil && string(second) == string(bytes))
	delete(second)
	// `any` is intentionally marshal-only: generic unmarshal destinations reject it.
}

accepted_prefix :: proc(
	writer: ^test_support.Scripted_Writer,
	storage: []byte,
) -> int {
	count := 0
	for call in writer.calls[:min(writer.call_count, len(writer.calls))] {
		if call.mode != .Write || call.returned_count < 0 ||
		   call.returned_count > i64(call.requested_count) {
			continue
		}
		accepted := int(call.returned_count)
		requested := test_support.requested_bytes(call, writer.bytes)
		assert(count+accepted <= len(storage))
		copy(storage[count:count+accepted], requested[:accepted])
		count += accepted
	}
	return count
}

run_writer_fault_injection :: proc(
	source: ^Property_Root,
	canonical: []byte,
	ordinal: int,
	step: test_support.Scripted_Write,
	expected: io.Error,
) {
	steps: [512]test_support.Scripted_Write
	for index in 0..<ordinal-1 {
		steps[index] = {count_kind = .Full}
	}
	steps[ordinal-1] = step
	calls: [512]test_support.Scripted_Writer_Call
	requested: [8192]byte
	writer: test_support.Scripted_Writer
	test_support.scripted_writer_init(&writer, steps[:ordinal], calls[:], requested[:])
	events: [2048]test_support.Allocator_Event
	live: [512]test_support.Live_Allocation
	observed: test_support.Observed_Allocator
	test_support.observed_allocator_init(&observed, context.allocator, events[:], live[:])
	selected := test_support.observed_allocator(&observed)
	state: Codec_State
	registry := init_property_registry(&state)
	options := toml.Marshal_Options{codecs = &registry}
	err := toml.marshal_to_writer(
		test_support.scripted_writer(&writer),
		source^,
		&options,
		selected,
	)
	actual, ok := err.(io.Error)
	assert(ok && actual == expected)
	assert(writer.write_count == ordinal && writer.call_count == ordinal)
	prefix: [8192]byte
	prefix_count := accepted_prefix(&writer, prefix[:])
	assert(prefix_count <= len(canonical))
	assert(string(prefix[:prefix_count]) == string(canonical[:prefix_count]))
	toml.destroy_codec_registry(&registry)
	assert_allocator_clean(&observed)
}

writer_baseline_trace :: proc(
	source: ^Property_Root,
	canonical: []byte,
	calls: []test_support.Scripted_Writer_Call,
	requested: []byte,
) -> test_support.Scripted_Writer {
	writer: test_support.Scripted_Writer
	test_support.scripted_writer_init(&writer, nil, calls, requested)
	state: Codec_State
	registry := init_property_registry(&state)
	options := toml.Marshal_Options{codecs = &registry}
	err := toml.marshal_to_writer(
		test_support.scripted_writer(&writer), source^, &options,
	)
	assert(err == nil)
	assert(string(requested[:writer.byte_count]) == string(canonical))
	toml.destroy_codec_registry(&registry)
	return writer
}

run_writer_fault_case :: proc(input: []byte) {
	random := random_from_input(input)
	leaf: Property_Leaf
	source := make_property_source(&random, &leaf)
	defer cleanup_property_source(&source)
	state: Codec_State
	registry := init_property_registry(&state)
	canonical, marshal_error := toml.marshal(source, {codecs = &registry})
	assert(marshal_error == nil)
	defer delete(canonical)
	toml.destroy_codec_registry(&registry)

	baseline_calls: [512]test_support.Scripted_Writer_Call
	baseline_requested: [8192]byte
	baseline := writer_baseline_trace(
		&source, canonical, baseline_calls[:], baseline_requested[:],
	)
	ordinal := 1+int(input_byte(input, 2))%baseline.write_count
	request_count := baseline.calls[ordinal-1].requested_count
	mode := int(input_byte(input, 3))%3
	step: test_support.Scripted_Write
	expected: io.Error
	switch mode {
	case 0:
		step = {
			count_kind = .Exact,
			count = i64(int(input_byte(input, 4))%request_count),
		}
		expected = .Short_Write
	case 1:
		step = {count_kind = .Negative}
		expected = .Invalid_Write
	case 2:
		step = {
			count_kind = .Exact,
			count = i64(int(input_byte(input, 4))%(request_count+1)),
			error = .Permission_Denied,
		}
		expected = .Permission_Denied
	}
	run_writer_fault_injection(&source, canonical, ordinal, step, expected)
}

run_writer_fault_matrix :: proc(input: []byte) {
	random := random_from_input(input)
	leaf: Property_Leaf
	source := make_property_source(&random, &leaf)
	defer cleanup_property_source(&source)
	state: Codec_State
	registry := init_property_registry(&state)
	canonical, marshal_error := toml.marshal(source, {codecs = &registry})
	assert(marshal_error == nil)
	defer delete(canonical)
	toml.destroy_codec_registry(&registry)

	baseline_calls: [512]test_support.Scripted_Writer_Call
	baseline_requested: [8192]byte
	baseline := writer_baseline_trace(
		&source, canonical, baseline_calls[:], baseline_requested[:],
	)
	explicit_errors := [?]io.Error{
		.EOF, .Unexpected_EOF, .Short_Write, .Invalid_Write, .Short_Buffer,
		.No_Progress, .Invalid_Whence, .Invalid_Offset, .Invalid_Unread,
		.Negative_Read, .Negative_Write, .Negative_Count, .Buffer_Full,
		.Unknown, .No_Size, .Permission_Denied, .Closed, .Unsupported,
	}
	for ordinal in 1..=baseline.write_count {
		request_count := baseline.calls[ordinal-1].requested_count
		assert(request_count > 0)
		for returned_count in 0..<request_count {
			run_writer_fault_injection(
				&source, canonical, ordinal,
				{count_kind = .Exact, count = i64(returned_count)},
				.Short_Write,
			)
		}
		run_writer_fault_injection(
			&source, canonical, ordinal, {count_kind = .Negative}, .Invalid_Write,
		)
		run_writer_fault_injection(
			&source, canonical, ordinal, {count_kind = .Past_End}, .Invalid_Write,
		)
		for explicit_error in explicit_errors {
			for returned_count in 0..=request_count {
				run_writer_fault_injection(
					&source, canonical, ordinal,
					{
						count_kind = .Exact,
						count = i64(returned_count),
						error = explicit_error,
					},
					explicit_error,
				)
			}
			run_writer_fault_injection(
				&source, canonical, ordinal,
				{count_kind = .Negative, error = explicit_error},
				explicit_error,
			)
			run_writer_fault_injection(
				&source, canonical, ordinal,
				{count_kind = .Past_End, error = explicit_error},
				explicit_error,
			)
		}
	}
}

measure_marshal_allocation_count :: proc(input: []byte) -> int {
	random := random_from_input(input)
	leaf: Property_Leaf
	source := make_property_source(&random, &leaf)
	defer cleanup_property_source(&source)
	events: [2048]test_support.Allocator_Event
	live: [512]test_support.Live_Allocation
	observed: test_support.Observed_Allocator
	test_support.observed_allocator_init(&observed, context.allocator, events[:], live[:])
	selected := test_support.observed_allocator(&observed)
	state: Codec_State
	registry := init_property_registry(&state)
	bytes, err := toml.marshal(source, {codecs = &registry}, selected)
	assert(err == nil)
	assert(delete(bytes, selected) == nil)
	toml.destroy_codec_registry(&registry)
	count := observed.allocation_request_count
	assert(count > 0)
	assert_allocator_clean(&observed)
	return count
}

run_marshal_allocation_at :: proc(input: []byte, fail_at: int, expect_failure: bool) {
	random := random_from_input(input)
	leaf: Property_Leaf
	source := make_property_source(&random, &leaf)
	defer cleanup_property_source(&source)
	events: [2048]test_support.Allocator_Event
	live: [512]test_support.Live_Allocation
	observed: test_support.Observed_Allocator
	test_support.observed_allocator_init(&observed, context.allocator, events[:], live[:])
	observed.fail_at_allocation = fail_at
	observed.failure_error = .Invalid_Argument
	selected := test_support.observed_allocator(&observed)
	state: Codec_State
	registry := init_property_registry(&state)
	bytes, err := toml.marshal(source, {codecs = &registry}, selected)
	if expect_failure {
		allocator_error, exact := err.(runtime.Allocator_Error)
		assert(exact && allocator_error == .Invalid_Argument)
		assert(raw_data(bytes) == nil && len(bytes) == 0)
	} else {
		assert(err == nil)
		assert(delete(bytes, selected) == nil)
	}
	toml.destroy_codec_registry(&registry)
	assert_allocator_clean(&observed)
}

run_marshal_allocation_failure_case :: proc(input: []byte) {
	count := measure_marshal_allocation_count(input)
	fail_at := 1+int(input_byte(input, 5))%count
	run_marshal_allocation_at(input, fail_at, true)
}

measure_writer_allocation_count :: proc(input: []byte) -> int {
	random := random_from_input(input)
	leaf: Property_Leaf
	source := make_property_source(&random, &leaf)
	defer cleanup_property_source(&source)
	events: [2048]test_support.Allocator_Event
	live: [512]test_support.Live_Allocation
	observed: test_support.Observed_Allocator
	test_support.observed_allocator_init(&observed, context.allocator, events[:], live[:])
	calls: [512]test_support.Scripted_Writer_Call
	requested: [8192]byte
	writer: test_support.Scripted_Writer
	test_support.scripted_writer_init(&writer, nil, calls[:], requested[:])
	state: Codec_State
	registry := init_property_registry(&state)
	options := toml.Marshal_Options{codecs = &registry}
	err := toml.marshal_to_writer(
		test_support.scripted_writer(&writer), source, &options,
		test_support.observed_allocator(&observed),
	)
	assert(err == nil && writer.write_count > 0)
	toml.destroy_codec_registry(&registry)
	count := observed.allocation_request_count
	assert(count > 0)
	assert_allocator_clean(&observed)
	return count
}

run_writer_allocation_at :: proc(input: []byte, fail_at: int, expect_failure: bool) {
	random := random_from_input(input)
	leaf: Property_Leaf
	source := make_property_source(&random, &leaf)
	defer cleanup_property_source(&source)
	events: [2048]test_support.Allocator_Event
	live: [512]test_support.Live_Allocation
	observed: test_support.Observed_Allocator
	test_support.observed_allocator_init(&observed, context.allocator, events[:], live[:])
	observed.fail_at_allocation = fail_at
	observed.failure_error = .Invalid_Argument
	calls: [512]test_support.Scripted_Writer_Call
	requested: [8192]byte
	writer: test_support.Scripted_Writer
	test_support.scripted_writer_init(&writer, nil, calls[:], requested[:])
	state: Codec_State
	registry := init_property_registry(&state)
	options := toml.Marshal_Options{codecs = &registry}
	err := toml.marshal_to_writer(
		test_support.scripted_writer(&writer), source, &options,
		test_support.observed_allocator(&observed),
	)
	if expect_failure {
		allocator_error, exact := err.(runtime.Allocator_Error)
		assert(exact && allocator_error == .Invalid_Argument)
		assert(writer.call_count == 0 && writer.write_count == 0)
	} else {
		assert(err == nil && writer.write_count > 0)
	}
	toml.destroy_codec_registry(&registry)
	assert_allocator_clean(&observed)
}

run_writer_allocation_failure_case :: proc(input: []byte) {
	count := measure_writer_allocation_count(input)
	fail_at := 1+int(input_byte(input, 7))%count
	run_writer_allocation_at(input, fail_at, true)
}

marshal_property_fixture :: proc(input: []byte) -> []byte {
	random := random_from_input(input)
	leaf: Property_Leaf
	source := make_property_source(&random, &leaf)
	defer cleanup_property_source(&source)
	state: Codec_State
	registry := init_property_registry(&state)
	bytes, err := toml.marshal(source, {codecs = &registry})
	assert(err == nil)
	toml.destroy_codec_registry(&registry)
	return bytes
}

measure_unmarshal_parse_allocation_count :: proc(input: []byte) -> int {
	bytes := marshal_property_fixture(input)
	defer delete(bytes)
	events: [2048]test_support.Allocator_Event
	live: [512]test_support.Live_Allocation
	observed: test_support.Observed_Allocator
	test_support.observed_allocator_init(&observed, context.allocator, events[:], live[:])
	invalid_root: i32
	err := toml.unmarshal(
		bytes, &invalid_root, allocator = test_support.observed_allocator(&observed),
	)
	diagnostic, ok := err.(toml.Unmarshal_Diagnostic)
	assert(ok)
	data, data_ok := diagnostic.detail.(toml.Unmarshal_Data_Error)
	assert(data_ok && data.kind == .Invalid_Root_Shape)
	count := observed.allocation_request_count
	assert(count > 0)
	assert_allocator_clean(&observed)
	return count
}

measure_unmarshal_allocation_count :: proc(input: []byte) -> int {
	bytes := marshal_property_fixture(input)
	defer delete(bytes)
	events: [2048]test_support.Allocator_Event
	live: [512]test_support.Live_Allocation
	observed: test_support.Observed_Allocator
	test_support.observed_allocator_init(&observed, context.allocator, events[:], live[:])
	selected := test_support.observed_allocator(&observed)
	state: Codec_State
	registry := init_property_registry(&state)
	destination := Property_Root{defaulted = 777, ignored = "kept"}
	err := toml.unmarshal(bytes, &destination, {codecs = &registry}, selected)
	assert(err == nil)
	count := observed.allocation_request_count
	cleanup_property_destination(&destination, selected)
	toml.destroy_codec_registry(&registry)
	assert(count > 0)
	assert_allocator_clean(&observed)
	return count
}

property_destination_is_initial :: proc(destination: ^Property_Root) -> bool {
	return destination.codec == 0 && destination.renamed == 0 &&
	       destination.defaulted == 777 && destination.missing_owned == "" &&
	       destination.ignored == "kept" && destination.fixed == {} &&
	       raw_data(destination.slice) == nil &&
	       destination.dynamic_values.allocator.procedure == nil &&
	       destination.mapping.allocator.procedure == nil &&
	       destination.pointer == nil && destination.optional == nil &&
	       destination.date == {}
}

property_destination_is_cleanable_prefix :: proc(
	destination, source: ^Property_Root,
) -> bool {
	if destination.codec != source.codec ||
	   (destination.renamed != 0 && destination.renamed != source.renamed) ||
	   destination.defaulted != 777 || destination.missing_owned != "" ||
	   destination.ignored != "kept" ||
	   (destination.date != temporal.Local_Date{} && destination.date != source.date) {
		return false
	}
	for value, index in destination.fixed {
		if value != 0 && value != source.fixed[index] {return false}
	}
	if len(destination.slice) != 0 && len(destination.slice) != len(source.slice) {
		return false
	}
	for value, index in destination.slice {
		if value != "" && value != source.slice[index] {return false}
	}
	if len(destination.dynamic_values) != 0 &&
	   len(destination.dynamic_values) != len(source.dynamic_values) {
		return false
	}
	for value, index in destination.dynamic_values {
		if value != 0 && value != source.dynamic_values[index] {return false}
	}
	for key, value in destination.mapping {
		expected, ok := source.mapping[key]
		if !ok || value != expected {return false}
	}
	if destination.pointer != nil {
		if destination.pointer.text != "" &&
		   destination.pointer.text != source.pointer.text {return false}
		if destination.pointer.number != 0 &&
		   destination.pointer.number != source.pointer.number {return false}
	}
	if optional, ok := destination.optional.(Property_Leaf); ok {
		expected := source.optional.(Property_Leaf)
		if optional.text != "" && optional.text != expected.text {return false}
		if optional.number != 0 && optional.number != expected.number {return false}
	}
	return true
}

run_unmarshal_allocation_at :: proc(
	input: []byte,
	fail_at, parse_allocation_count: int,
	expect_failure: bool,
) -> bool {
	random := random_from_input(input)
	leaf: Property_Leaf
	source := make_property_source(&random, &leaf)
	defer cleanup_property_source(&source)
	bytes := marshal_property_fixture(input)
	defer delete(bytes)
	events: [2048]test_support.Allocator_Event
	live: [512]test_support.Live_Allocation
	observed: test_support.Observed_Allocator
	test_support.observed_allocator_init(&observed, context.allocator, events[:], live[:])
	observed.fail_at_allocation = fail_at
	observed.failure_error = .Invalid_Argument
	selected := test_support.observed_allocator(&observed)
	state: Codec_State
	registry := init_property_registry(&state)
	destination := Property_Root{defaulted = 777, ignored = "kept"}
	err := toml.unmarshal(bytes, &destination, {codecs = &registry}, selected)
	installed := state.unmarshal_count > 0
	if expect_failure {
		if fail_at <= parse_allocation_count {
			wrapped, wrapped_ok := err.(toml.Unmarshal_Parse_Error)
			assert(wrapped_ok)
			nested, nested_ok := wrapped.error.(runtime.Allocator_Error)
			assert(nested_ok && nested == .Invalid_Argument)
		} else {
			allocator_error, exact := err.(runtime.Allocator_Error)
			assert(exact && allocator_error == .Invalid_Argument)
		}
		if !installed {
			assert(property_destination_is_initial(&destination))
		} else {
			assert(state.unmarshal_values[0] == source.codec)
			assert(property_destination_is_cleanable_prefix(&destination, &source))
		}
	} else {
		assert(err == nil)
		assert(installed)
		assert(property_values_equal(&destination, &source))
	}
	cleanup_property_destination(&destination, selected)
	toml.destroy_codec_registry(&registry)
	assert_allocator_clean(&observed)
	return installed
}

run_unmarshal_install_failure_case :: proc(input: []byte) -> bool {
	count := measure_unmarshal_allocation_count(input)
	parse_count := measure_unmarshal_parse_allocation_count(input)
	assert(parse_count < count)
	fail_at := 1+int(input_byte(input, 6))%count
	return run_unmarshal_allocation_at(input, fail_at, parse_count, true)
}

coverage_typed_codec_target :: proc(input: []byte) {
	selector := int(input_byte(input, 0))%8
	switch selector {
	case 0:
		run_round_trip_case(input)
	case 1:
		run_unknown_preflight_case()
	case 2:
		run_transaction_case()
	case 3:
		run_active_cycle_case()
	case 4:
		run_any_case(input)
	case 5:
		run_writer_fault_case(input)
	case 6:
		run_marshal_allocation_failure_case(input)
		run_writer_allocation_failure_case(input)
	case 7:
		_ = run_unmarshal_install_failure_case(input)
	}
}

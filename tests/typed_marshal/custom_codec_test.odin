package typed_marshal_test

import "base:runtime"
import "core:io"
import "core:mem"
import "core:testing"
import "core:thread"
import toml "../.."
import temporal "../../temporal"
import test_support "../support"

Codec_Named_Integer :: distinct i32

Codec_Named_Root :: struct {
	value: Codec_Named_Integer,
}

Codec_Custom_Root :: distinct i32
Codec_Failing_Value :: distinct i32
Codec_Invalid_Value :: distinct i32
Codec_Allocator_Failure :: distinct i32

Codec_Map_Value :: struct {
	order: i32,
}

Codec_Map_Root :: struct {
	values: map[string]Codec_Map_Value,
}

Codec_Failing_Root :: struct {
	value: Codec_Failing_Value,
}

Codec_Item :: struct {
	raw: i32,
}

Codec_Child :: struct {
	raw: i32,
}

Codec_Optional_Child :: union {
	Codec_Child,
}

Codec_Exact_Optional :: union {
	Codec_Child,
}

Codec_Selection_Root :: struct {
	direct:   Codec_Item,
	pointer:  ^Codec_Item,
	child_pointer: ^Codec_Child,
	optional: Codec_Optional_Child,
	exact_optional: Codec_Exact_Optional,
	payload:  any,
	date:     temporal.Local_Date,
	omitted:  Codec_Named_Integer `toml:",omitempty"`,
	empty:    [0]Unsupported_Enum,
	mapping:  map[Named_Map_Key]i32,
}

Codec_Invalid_Mode :: enum {
	Invalid_Text,
	Invalid_Temporal,
	Duplicate_Key,
	Uninitialized_Container,
	Cycle,
	Alias,
	Allocator_Mismatch,
	Depth,
}

Codec_Invalid_State :: struct {
	mode:            Codec_Invalid_Mode,
	other_allocator: mem.Allocator,
	call_count:      int,
}

Codec_Shared_State :: struct {
	value:      toml.Value,
	call_count: int,
}

Codec_Order_State :: struct {
	values: [3]i32,
	count:  int,
}

Codec_Concurrent_State :: struct {
	registry: ^toml.Codec_Registry,
	success:  bool,
}

Codec_Selection_State :: struct {
	item_calls:    int,
	pointer_calls: int,
	child_calls:   int,
	exact_optional_calls: int,
	any_calls:     int,
	temporal_calls: int,
	omitted_calls: int,
	empty_calls:   int,
	map_key_calls: int,
}

Codec_Root_State :: struct {
	template: ^toml.Value,
	call_count: int,
}

Codec_Invocation_State :: struct {
	call_count:         int,
	expected_source:    Codec_Named_Integer,
	expected_allocator: mem.Allocator,
	expected_loc:       runtime.Source_Code_Location,
	contract_matched:   bool,
}

codec_location_equal :: proc(a, b: runtime.Source_Code_Location) -> bool {
	return a.file_path == b.file_path && a.line == b.line &&
	       a.column == b.column && a.procedure == b.procedure
}

codec_allocator_equal :: proc(a, b: mem.Allocator) -> bool {
	return a.procedure == b.procedure && a.data == b.data
}

marshal_named_integer :: proc(
	source: any,
	user_data: rawptr,
	allocator: mem.Allocator,
	loc: runtime.Source_Code_Location,
) -> (toml.Value, toml.Codec_Callback_Error) {
	state := (^Codec_Invocation_State)(user_data)
	state.call_count += 1
	state.contract_matched = source.id == typeid_of(Codec_Named_Integer) &&
	                         (^Codec_Named_Integer)(source.data)^ == state.expected_source &&
	                         codec_allocator_equal(allocator, state.expected_allocator) &&
	                         codec_location_equal(loc, state.expected_loc)
	return toml.Value(toml.Integer(99)), nil
}

codec_owned_string :: proc(
	text: string,
	allocator: mem.Allocator,
) -> (string, runtime.Allocator_Error) {
	bytes, err := make([]byte, len(text), allocator)
	if err != nil {
		return "", err
	}
	copy(bytes, transmute([]byte)text)
	return string(bytes), nil
}

marshal_invalid_value :: proc(
	source: any,
	user_data: rawptr,
	allocator: mem.Allocator,
	loc: runtime.Source_Code_Location,
) -> (toml.Value, toml.Codec_Callback_Error) {
	_, _ = source, loc
	state := (^Codec_Invalid_State)(user_data)
	state.call_count += 1
	switch state.mode {
	case .Invalid_Text:
		bytes, err := make([]byte, 1, allocator)
		if err != nil {
			return {}, err
		}
		bytes[0] = 0xff
		return toml.Value(toml.String(string(bytes))), nil
	case .Invalid_Temporal:
		return toml.Value(temporal.Local_Date{2024, 2, 30}), nil
	case .Duplicate_Key:
		table, err := make(toml.Table, 2, allocator)
		if err != nil {
			return {}, err
		}
		first, first_error := codec_owned_string("same", allocator)
		if first_error != nil {
			delete(table)
			return {}, first_error
		}
		table[0] = {key = first, value = toml.Value(toml.Integer(1))}
		table[1] = {key = first, value = toml.Value(toml.Integer(2))}
		return toml.Value(table), nil
	case .Uninitialized_Container:
		return toml.Value(toml.Array{}), nil
	case .Cycle:
		array, err := make(toml.Array, 1, allocator)
		if err != nil {
			return {}, err
		}
		array[0] = toml.Value(array)
		return toml.Value(array), nil
	case .Alias:
		array, err := make(toml.Array, 2, allocator)
		if err != nil {
			return {}, err
		}
		shared, text_error := codec_owned_string("shared", allocator)
		if text_error != nil {
			delete(array)
			return {}, text_error
		}
		array[0] = toml.Value(toml.String(shared))
		array[1] = toml.Value(toml.String(shared))
		return toml.Value(array), nil
	case .Allocator_Mismatch:
		outer, err := make(toml.Array, 1, allocator)
		if err != nil {
			return {}, err
		}
		inner, inner_error := make(toml.Array, 1, state.other_allocator)
		if inner_error != nil {
			delete(outer)
			return {}, inner_error
		}
		text, text_error := codec_owned_string("other", state.other_allocator)
		if text_error != nil {
			delete(inner)
			delete(outer)
			return {}, text_error
		}
		inner[0] = toml.Value(toml.String(text))
		outer[0] = toml.Value(inner)
		return toml.Value(outer), nil
	case .Depth:
		outer, err := make(toml.Array, 1, allocator)
		if err != nil {
			return {}, err
		}
		inner, inner_error := make(toml.Array, 1, allocator)
		if inner_error != nil {
			delete(outer)
			return {}, inner_error
		}
		inner[0] = toml.Value(toml.Integer(1))
		outer[0] = toml.Value(inner)
		return toml.Value(outer), nil
	}
	unreachable()
}

marshal_concurrent_value :: proc(
	source: any,
	user_data: rawptr,
	allocator: mem.Allocator,
	loc: runtime.Source_Code_Location,
) -> (toml.Value, toml.Codec_Callback_Error) {
	_, _ = allocator, loc
	expected := (^Codec_Named_Integer)(user_data)^
	assert(source.id == typeid_of(Codec_Named_Integer))
	assert((^Codec_Named_Integer)(source.data)^ == expected)
	return toml.Value(toml.Integer(77)), nil
}

codec_concurrent_worker :: proc(data: rawptr) {
	state := (^Codec_Concurrent_State)(data)
	state.success = true
	for _ in 0..<1_000 {
		bytes, err := toml.marshal(
			Codec_Named_Root{value = 7},
			{codecs = state.registry},
		)
		if err != nil || string(bytes) != `"value" = 77
` {
			if raw_data(bytes) != nil {
				delete(bytes)
			}
			state.success = false
			return
		}
		delete(bytes)
	}
}

marshal_ordered_value :: proc(
	source: any,
	user_data: rawptr,
	allocator: mem.Allocator,
	loc: runtime.Source_Code_Location,
) -> (toml.Value, toml.Codec_Callback_Error) {
	_, _ = allocator, loc
	state := (^Codec_Order_State)(user_data)
	value := (^Codec_Map_Value)(source.data)^
	state.values[state.count] = value.order
	state.count += 1
	return toml.Value(toml.Integer(value.order)), nil
}

marshal_allocator_failure :: proc(
	source: any,
	user_data: rawptr,
	allocator: mem.Allocator,
	loc: runtime.Source_Code_Location,
) -> (toml.Value, toml.Codec_Callback_Error) {
	_, _, _ = source, allocator, loc
	return {}, (^runtime.Allocator_Error)(user_data)^
}

marshal_shared_value :: proc(
	source: any,
	user_data: rawptr,
	allocator: mem.Allocator,
	loc: runtime.Source_Code_Location,
) -> (toml.Value, toml.Codec_Callback_Error) {
	_, _, _ = source, allocator, loc
	state := (^Codec_Shared_State)(user_data)
	state.call_count += 1
	return state.value, nil
}

marshal_selection_value :: proc(
	source: any,
	user_data: rawptr,
	allocator: mem.Allocator,
	loc: runtime.Source_Code_Location,
) -> (toml.Value, toml.Codec_Callback_Error) {
	_, _ = allocator, loc
	state := (^Codec_Selection_State)(user_data)
	switch source.id {
	case typeid_of(Codec_Item):
		state.item_calls += 1
		return toml.Value(toml.Integer(11)), nil
	case typeid_of(^Codec_Item):
		state.pointer_calls += 1
		return toml.Value(toml.Integer(22)), nil
	case typeid_of(Codec_Child):
		state.child_calls += 1
		return toml.Value(toml.Integer(23)), nil
	case typeid_of(Codec_Exact_Optional):
		state.exact_optional_calls += 1
		return toml.Value(toml.Integer(24)), nil
	case typeid_of(any):
		state.any_calls += 1
		return toml.Value(toml.Integer(33)), nil
	case typeid_of(temporal.Local_Date):
		state.temporal_calls += 1
		return toml.Value(toml.Integer(66)), nil
	case typeid_of(Codec_Named_Integer):
		state.omitted_calls += 1
		return toml.Value(toml.Integer(44)), nil
	case typeid_of(Unsupported_Enum):
		state.empty_calls += 1
		return toml.Value(toml.Integer(55)), nil
	case typeid_of(Named_Map_Key):
		state.map_key_calls += 1
		return toml.Value(toml.String("not-a-key")), nil
	}
	unreachable()
}

marshal_failing_value :: proc(
	source: any,
	user_data: rawptr,
	allocator: mem.Allocator,
	loc: runtime.Source_Code_Location,
) -> (toml.Value, toml.Codec_Callback_Error) {
	_, _, _ = source, allocator, loc
	code := (^u32)(user_data)^
	return {}, toml.Codec_Callback_Failure{code = code}
}

marshal_invalid_root :: proc(
	source: any,
	user_data: rawptr,
	allocator: mem.Allocator,
	loc: runtime.Source_Code_Location,
) -> (toml.Value, toml.Codec_Callback_Error) {
	_, _, _ = source, allocator, loc
	count := (^int)(user_data)
	count^ += 1
	return toml.Value(toml.Integer(1)), nil
}

marshal_custom_root :: proc(
	source: any,
	user_data: rawptr,
	allocator: mem.Allocator,
	loc: runtime.Source_Code_Location,
) -> (toml.Value, toml.Codec_Callback_Error) {
	_ = source
	state := (^Codec_Root_State)(user_data)
	state.call_count += 1
	value, err := toml.clone_value(state.template, allocator, loc)
	if err != nil {
		allocator_error, ok := err.(runtime.Allocator_Error)
		assert(ok)
		return {}, allocator_error
	}
	return value, nil
}

@(test)
test_marshal_codec_exact_lookup_overrides_named_generic_mapping_once :: proc(t: ^testing.T) {
	registry, registry_error := toml.init_codec_registry()
	assert(registry_error == nil)
	defer toml.destroy_codec_registry(&registry)

	selected := context.allocator
	expected_loc := runtime.Source_Code_Location{
		file_path = "codec-contract.odin",
		line = 123,
		column = 7,
		procedure = "codec_contract",
	}
	state := Codec_Invocation_State{
		expected_source = 7,
		expected_allocator = selected,
		expected_loc = expected_loc,
	}
	assert(toml.register_marshaler(
		&registry,
		typeid_of(Codec_Named_Integer),
		{procedure = marshal_named_integer, user_data = &state},
	) == nil)

	bytes, err := toml.marshal(
		Codec_Named_Root{value = 7},
		{codecs = &registry},
		selected,
		expected_loc,
	)
	testing.expect(t, err == nil)
	if err == nil {
		defer delete(bytes, selected)
		testing.expect_value(t, string(bytes), `"value" = 99
`)
	}
	testing.expect_value(t, state.call_count, 1)
	testing.expect(t, state.contract_matched)
}

@(test)
test_marshal_codec_can_supply_a_table_shaped_typed_root :: proc(t: ^testing.T) {
	template_document, parse_error := toml.parse_string(`answer = 42`)
	assert(parse_error == nil)
	defer toml.destroy_document(&template_document)
	template := toml.Value(template_document.root)
	state := Codec_Root_State{template = &template}

	registry, registry_error := toml.init_codec_registry()
	assert(registry_error == nil)
	defer toml.destroy_codec_registry(&registry)
	assert(toml.register_marshaler(
		&registry,
		typeid_of(Codec_Custom_Root),
		{procedure = marshal_custom_root, user_data = &state},
	) == nil)

	bytes, err := toml.marshal(
		Codec_Custom_Root(7),
		{codecs = &registry},
	)
	testing.expect(t, err == nil)
	if err == nil {
		defer delete(bytes)
		testing.expect_value(t, string(bytes), `"answer" = 42
`)
	}
	testing.expect_value(t, state.call_count, 1)
}

@(test)
test_marshal_codec_root_must_return_a_semantic_table :: proc(t: ^testing.T) {
	registry, registry_error := toml.init_codec_registry()
	assert(registry_error == nil)
	defer toml.destroy_codec_registry(&registry)
	call_count := 0
	assert(toml.register_marshaler(
		&registry,
		typeid_of(Codec_Custom_Root),
		{procedure = marshal_invalid_root, user_data = &call_count},
	) == nil)
	failed, err := toml.marshal(Codec_Custom_Root(1), {codecs = &registry})
	testing.expect(t, raw_data(failed) == nil)
	data := marshal_data_kind(t, err)
	testing.expect_value(t, data.kind, toml.Marshal_Data_Error_Kind.Invalid_Root_Shape)
	testing.expect_value(t, data.source_type, typeid_of(Codec_Custom_Root))
	testing.expect_value(t, call_count, 1)
}

@(test)
test_marshal_codec_selection_respects_wrappers_omission_empty_types_and_map_keys :: proc(t: ^testing.T) {
	registry, registry_error := toml.init_codec_registry()
	assert(registry_error == nil)
	defer toml.destroy_codec_registry(&registry)
	state: Codec_Selection_State
	registered_types := [?]typeid{
		typeid_of(Codec_Item),
		typeid_of(^Codec_Item),
		typeid_of(Codec_Child),
		typeid_of(Codec_Exact_Optional),
		typeid_of(any),
		typeid_of(temporal.Local_Date),
		typeid_of(Codec_Named_Integer),
		typeid_of(Unsupported_Enum),
		typeid_of(Named_Map_Key),
	}
	for id in registered_types {
		assert(toml.register_marshaler(
			&registry,
			id,
			{procedure = marshal_selection_value, user_data = &state},
		) == nil)
	}

	item := Codec_Item{raw = 7}
	child := Codec_Child{raw = 8}
	mapping := make(map[Named_Map_Key]i32)
	defer delete(mapping)
	mapping["b"] = 2
	mapping["a"] = 1
	bytes, err := toml.marshal(
		Codec_Selection_Root{
			direct = item,
			pointer = &item,
			child_pointer = &child,
			optional = child,
			exact_optional = child,
			payload = item,
			date = {2024, 2, 30},
			mapping = mapping,
		},
		{codecs = &registry},
	)
	testing.expect(t, err == nil)
	if err == nil {
		defer delete(bytes)
		testing.expect_value(t, string(bytes), `"direct" = 11
"pointer" = 22
"child_pointer" = 23
"optional" = 23
"exact_optional" = 24
"payload" = 11
"date" = 66
"empty" = []
"mapping" = { "a" = 1, "b" = 2 }
`)
	}
	testing.expect_value(t, state.item_calls, 2)
	testing.expect_value(t, state.pointer_calls, 1)
	testing.expect_value(t, state.child_calls, 2)
	testing.expect_value(t, state.exact_optional_calls, 1)
	testing.expect_value(t, state.any_calls, 0)
	testing.expect_value(t, state.temporal_calls, 1)
	testing.expect_value(t, state.omitted_calls, 0)
	testing.expect_value(t, state.empty_calls, 0)
	testing.expect_value(t, state.map_key_calls, 0)
}

@(test)
test_marshal_codec_map_values_run_once_in_canonical_order_and_writer_matches :: proc(t: ^testing.T) {
	registry, registry_error := toml.init_codec_registry()
	assert(registry_error == nil)
	defer toml.destroy_codec_registry(&registry)
	state: Codec_Order_State
	assert(toml.register_marshaler(
		&registry,
		typeid_of(Codec_Map_Value),
		{procedure = marshal_ordered_value, user_data = &state},
	) == nil)
	mapping := make(map[string]Codec_Map_Value)
	defer delete(mapping)
	mapping["c"] = {order = 3}
	mapping["a"] = {order = 1}
	mapping["b"] = {order = 2}
	options := toml.Marshal_Options{codecs = &registry}
	bytes, err := toml.marshal(Codec_Map_Root{values = mapping}, options)
	assert(err == nil)
	defer delete(bytes)
	testing.expect_value(t, string(bytes), `"values" = { "a" = 1, "b" = 2, "c" = 3 }
`)
	testing.expect_value(t, state.count, 3)
	testing.expect_value(t, state.values, [3]i32{1, 2, 3})

	state = {}
	calls: [32]test_support.Scripted_Writer_Call
	requested: [1024]byte
	writer_state: test_support.Scripted_Writer
	test_support.scripted_writer_init(&writer_state, nil, calls[:], requested[:])
	writer_error := toml.marshal_to_writer(
		test_support.scripted_writer(&writer_state),
		Codec_Map_Root{values = mapping},
		&options,
	)
	testing.expect(t, writer_error == nil)
	testing.expect_value(t, string(requested[:writer_state.byte_count]), string(bytes))
	testing.expect_value(t, state.count, 3)
	testing.expect_value(t, state.values, [3]i32{1, 2, 3})
}

@(test)
test_marshal_codec_frozen_registry_supports_concurrent_calls :: proc(t: ^testing.T) {
	registry, registry_error := toml.init_codec_registry()
	assert(registry_error == nil)
	expected := Codec_Named_Integer(7)
	assert(toml.register_marshaler(
		&registry,
		typeid_of(Codec_Named_Integer),
		{procedure = marshal_concurrent_value, user_data = &expected},
	) == nil)

	THREAD_COUNT :: 4
	states: [THREAD_COUNT]Codec_Concurrent_State
	threads: [THREAD_COUNT]^thread.Thread
	for index in 0..<THREAD_COUNT {
		states[index] = {registry = &registry}
		threads[index] = thread.create_and_start_with_data(
			&states[index],
			codec_concurrent_worker,
		)
		testing.expect(t, threads[index] != nil)
	}
	for worker in threads {
		if worker != nil {
			thread.destroy(worker)
		}
	}
	for state in states {
		testing.expect(t, state.success)
	}
	toml.destroy_codec_registry(&registry)
}

@(test)
test_marshal_codec_values_use_semantic_validation_and_cleanup :: proc(t: ^testing.T) {
	backing := context.allocator
	other_events: [16]test_support.Allocator_Event
	other_live: [8]test_support.Live_Allocation
	other_state: test_support.Observed_Allocator
	test_support.observed_allocator_init(
		&other_state,
		backing,
		other_events[:],
		other_live[:],
	)
	other_allocator := test_support.observed_allocator(&other_state)

	cases := [?]struct {
		mode:     Codec_Invalid_Mode,
		kind:     toml.Marshal_Data_Error_Kind,
		depth:    int,
		temporal: temporal.Error,
	}{
		{.Invalid_Text, .Invalid_Text, 0, .None},
		{.Invalid_Temporal, .Invalid_Temporal, 0, .Invalid_Day},
		{.Duplicate_Key, .Duplicate_Key, 0, .None},
		{.Uninitialized_Container, .Invalid_Container, 0, .None},
		{.Cycle, .Codec_Value_Cycle, 0, .None},
		{.Alias, .Codec_Value_Ownership_Alias, 0, .None},
		{.Allocator_Mismatch, .Codec_Value_Allocator_Mismatch, 0, .None},
		{.Depth, {}, 2, .None},
	}
	for test_case in cases {
		events: [128]test_support.Allocator_Event
		live: [32]test_support.Live_Allocation
		allocator_state: test_support.Observed_Allocator
		test_support.observed_allocator_init(
			&allocator_state,
			backing,
			events[:],
			live[:],
		)
		selected := test_support.observed_allocator(&allocator_state)
		state := Codec_Invalid_State{
			mode = test_case.mode,
			other_allocator = other_allocator,
		}
		registry, registry_error := toml.init_codec_registry()
		assert(registry_error == nil)
		assert(toml.register_marshaler(
			&registry,
			typeid_of(Codec_Invalid_Value),
			{procedure = marshal_invalid_value, user_data = &state},
		) == nil)
		options := toml.Marshal_Options{
			max_depth = test_case.depth,
			codecs = &registry,
		}
		failed, err := toml.marshal(
			struct {value: Codec_Invalid_Value}{value = 1},
			options,
			selected,
		)
		testing.expect(t, raw_data(failed) == nil)
		diagnostic, diagnostic_ok := err.(toml.Marshal_Diagnostic)
		testing.expect(t, diagnostic_ok)
		if diagnostic_ok {
			if test_case.mode == .Depth {
				limit, limit_ok := diagnostic.detail.(toml.Marshal_Limit_Error)
				testing.expect(t, limit_ok)
				if limit_ok {
					testing.expect_value(
						t,
						limit,
						toml.Marshal_Limit_Error.Maximum_Depth_Exceeded,
					)
				}
			} else {
				data, data_ok := diagnostic.detail.(toml.Marshal_Data_Error)
				testing.expect(t, data_ok)
				if data_ok {
					testing.expect_value(t, data, toml.Marshal_Data_Error{
						kind = test_case.kind,
						source_type = typeid_of(Codec_Invalid_Value),
						temporal_error = test_case.temporal,
					})
				}
			}
			name, name_ok := diagnostic.path.segments[0].(string)
			testing.expect(t, name_ok)
			if name_ok {
				testing.expect_value(t, name, "value")
			}
			testing.expect_value(t, diagnostic.path.segment_count, u8(1))
			testing.expect_value(t, diagnostic.path.prefix_count, u8(1))
			testing.expect_value(t, diagnostic.path.total_segment_count, u16(1))
			testing.expect_value(t, diagnostic.path.omitted_segment_count, u16(0))
			testing.expect(t, !diagnostic.path.truncated)
		}
		testing.expect_value(t, state.call_count, 1)
		testing.expect_value(t, allocator_state.live_count, 0)
		testing.expect_value(t, allocator_state.foreign_release_count, 0)
		toml.destroy_codec_registry(&registry)
	}
	testing.expect_value(t, other_state.live_count, 0)
}

@(test)
test_marshal_codec_detects_aliases_between_separate_callback_results :: proc(t: ^testing.T) {
	backing := context.allocator
	events: [128]test_support.Allocator_Event
	live: [32]test_support.Live_Allocation
	allocator_state: test_support.Observed_Allocator
	test_support.observed_allocator_init(
		&allocator_state,
		backing,
		events[:],
		live[:],
	)
	selected := test_support.observed_allocator(&allocator_state)
	array, array_error := make(toml.Array, 1, selected)
	assert(array_error == nil)
	text, text_error := codec_owned_string("shared", selected)
	assert(text_error == nil)
	array[0] = toml.Value(toml.String(text))
	state := Codec_Shared_State{value = toml.Value(array)}

	registry, registry_error := toml.init_codec_registry()
	assert(registry_error == nil)
	defer toml.destroy_codec_registry(&registry)
	assert(toml.register_marshaler(
		&registry,
		typeid_of(Codec_Invalid_Value),
		{procedure = marshal_shared_value, user_data = &state},
	) == nil)
	failed, err := toml.marshal(
		struct {
			first:  Codec_Invalid_Value,
			second: Codec_Invalid_Value,
		}{1, 2},
		{codecs = &registry},
		selected,
	)
	state.value = {}
	testing.expect(t, raw_data(failed) == nil)
	data := marshal_data_kind(t, err)
	testing.expect_value(t, data.kind, toml.Marshal_Data_Error_Kind.Codec_Value_Ownership_Alias)
	testing.expect_value(t, data.source_type, typeid_of(Codec_Invalid_Value))
	diagnostic := err.(toml.Marshal_Diagnostic)
	name, name_ok := diagnostic.path.segments[0].(string)
	testing.expect(t, name_ok)
	if name_ok {
		testing.expect_value(t, name, "second")
	}
	testing.expect_value(t, state.call_count, 2)
	testing.expect_value(t, allocator_state.live_count, 0)
	testing.expect_value(t, allocator_state.foreign_release_count, 0)
}

@(test)
test_marshal_codec_owner_cleanup_survives_every_later_failure :: proc(t: ^testing.T) {
	template_document, parse_error := toml.parse_string(`nested = { text = "owned" }`)
	assert(parse_error == nil)
	defer toml.destroy_document(&template_document)
	template := toml.Value(template_document.root)
	registry, registry_error := toml.init_codec_registry()
	assert(registry_error == nil)
	defer toml.destroy_codec_registry(&registry)
	state := Codec_Root_State{template = &template}
	assert(toml.register_marshaler(
		&registry,
		typeid_of(Codec_Invalid_Value),
		{procedure = marshal_custom_root, user_data = &state},
	) == nil)
	options := toml.Marshal_Options{codecs = &registry}

	backing := context.allocator
	baseline_events: [1024]test_support.Allocator_Event
	baseline_live: [256]test_support.Live_Allocation
	baseline: test_support.Observed_Allocator
	test_support.observed_allocator_init(
		&baseline,
		backing,
		baseline_events[:],
		baseline_live[:],
	)
	selected := test_support.observed_allocator(&baseline)
	bytes, err := toml.marshal(
		struct {value: Codec_Invalid_Value}{value = 1},
		options,
		selected,
	)
	assert(err == nil)
	testing.expect_value(t, state.call_count, 1)
	allocation_count := baseline.allocation_request_count
	testing.expect_value(t, baseline.live_count, 1)
	delete(bytes, selected)
	testing.expect_value(t, baseline.live_count, 0)

	for fail_at in 1..=allocation_count {
		events: [1024]test_support.Allocator_Event
		live: [256]test_support.Live_Allocation
		allocator_state: test_support.Observed_Allocator
		test_support.observed_allocator_init(
			&allocator_state,
			backing,
			events[:],
			live[:],
		)
		allocator_state.fail_at_allocation = fail_at
		allocator_state.failure_error = .Out_Of_Memory
		state.call_count = 0
		failed, failure := toml.marshal(
			struct {value: Codec_Invalid_Value}{value = 1},
			options,
			test_support.observed_allocator(&allocator_state),
		)
		testing.expect(t, raw_data(failed) == nil)
		allocator_error, allocator_ok := failure.(runtime.Allocator_Error)
		testing.expect(t, allocator_ok)
		if allocator_ok {
			testing.expect_value(t, allocator_error, runtime.Allocator_Error.Out_Of_Memory)
		}
		testing.expect(t, state.call_count == 0 || state.call_count == 1)
		testing.expect_value(t, allocator_state.live_count, 0)
		testing.expect_value(t, allocator_state.foreign_release_count, 0)
	}

	writer_events: [1024]test_support.Allocator_Event
	writer_live: [256]test_support.Live_Allocation
	writer_allocator: test_support.Observed_Allocator
	test_support.observed_allocator_init(
		&writer_allocator,
		backing,
		writer_events[:],
		writer_live[:],
	)
	steps := [1]test_support.Scripted_Write{{
		count_kind = .Exact,
		count = 1,
		error = io.Error.Permission_Denied,
	}}
	calls: [32]test_support.Scripted_Writer_Call
	requested: [1024]byte
	writer_state: test_support.Scripted_Writer
	test_support.scripted_writer_init(
		&writer_state,
		steps[:],
		calls[:],
		requested[:],
	)
	state.call_count = 0
	writer_error := toml.marshal_to_writer(
		test_support.scripted_writer(&writer_state),
		struct {value: Codec_Invalid_Value}{value = 1},
		&options,
		test_support.observed_allocator(&writer_allocator),
	)
	exact_writer_error, writer_error_ok := writer_error.(io.Error)
	testing.expect(t, writer_error_ok)
	if writer_error_ok {
		testing.expect_value(t, exact_writer_error, io.Error.Permission_Denied)
	}
	testing.expect_value(t, state.call_count, 1)
	testing.expect_value(t, writer_state.write_count, 1)
	testing.expect_value(t, writer_allocator.live_count, 0)
	testing.expect_value(t, writer_allocator.foreign_release_count, 0)
}

@(test)
test_marshal_codec_configuration_and_callback_failures_are_distinct :: proc(t: ^testing.T) {
	registry, registry_error := toml.init_codec_registry()
	assert(registry_error == nil)
	code := u32(0x8bad_f00d)
	assert(toml.register_marshaler(
		&registry,
		typeid_of(Codec_Failing_Value),
		{procedure = marshal_failing_value, user_data = &code},
	) == nil)
	allocator_failure := runtime.Allocator_Error.Mode_Not_Implemented
	assert(toml.register_marshaler(
		&registry,
		typeid_of(Codec_Allocator_Failure),
		{procedure = marshal_allocator_failure, user_data = &allocator_failure},
	) == nil)

	failed, err := toml.marshal(
		Codec_Failing_Root{value = 3},
		{codecs = &registry},
	)
	testing.expect(t, raw_data(failed) == nil)
	diagnostic, diagnostic_ok := err.(toml.Marshal_Diagnostic)
	testing.expect(t, diagnostic_ok)
	if diagnostic_ok {
		codec_error, codec_ok := diagnostic.detail.(toml.Marshal_Codec_Error)
		testing.expect(t, codec_ok)
		if codec_ok {
			testing.expect_value(t, codec_error.registered_type, typeid_of(Codec_Failing_Value))
			testing.expect_value(t, codec_error.code, code)
		}
		name, name_ok := diagnostic.path.segments[0].(string)
		testing.expect(t, name_ok)
		if name_ok {
			testing.expect_value(t, name, "value")
		}
		testing.expect_value(t, diagnostic.path.segment_count, u8(1))
		testing.expect_value(t, diagnostic.path.prefix_count, u8(1))
		testing.expect_value(t, diagnostic.path.total_segment_count, u16(1))
		testing.expect_value(t, diagnostic.path.omitted_segment_count, u16(0))
		testing.expect(t, !diagnostic.path.truncated)
	}

	code = 0x1357_2468
	failed, err = toml.marshal(
		Codec_Failing_Root{value = 4},
		{codecs = &registry},
	)
	testing.expect(t, raw_data(failed) == nil)
	diagnostic, diagnostic_ok = err.(toml.Marshal_Diagnostic)
	testing.expect(t, diagnostic_ok)
	if diagnostic_ok {
		codec_error, codec_ok := diagnostic.detail.(toml.Marshal_Codec_Error)
		testing.expect(t, codec_ok)
		if codec_ok {
			testing.expect_value(t, codec_error, toml.Marshal_Codec_Error{
				registered_type = typeid_of(Codec_Failing_Value),
				code = 0x1357_2468,
			})
		}
		testing.expect_value(t, diagnostic.path.segment_count, u8(1))
		testing.expect_value(t, diagnostic.path.prefix_count, u8(1))
		testing.expect_value(t, diagnostic.path.total_segment_count, u16(1))
		testing.expect_value(t, diagnostic.path.omitted_segment_count, u16(0))
		testing.expect(t, !diagnostic.path.truncated)
	}

	failed, err = toml.marshal(
		struct {value: Codec_Allocator_Failure}{value = 1},
		{codecs = &registry},
	)
	testing.expect(t, raw_data(failed) == nil)
	exact_allocator_error, allocator_error_ok := err.(runtime.Allocator_Error)
	testing.expect(t, allocator_error_ok)
	if allocator_error_ok {
		testing.expect_value(t, exact_allocator_error, allocator_failure)
	}

	registry.initialized = false
	failed, err = toml.marshal(
		Codec_Failing_Root{value = 3},
		{codecs = &registry},
	)
	registry.initialized = true
	testing.expect(t, raw_data(failed) == nil)
	configuration, configuration_ok := err.(toml.Marshal_Configuration_Error)
	testing.expect(t, configuration_ok)
	if configuration_ok {
		testing.expect_value(
			t,
			configuration,
			toml.Marshal_Configuration_Error.Invalid_Codec_Registry,
		)
	}
	toml.destroy_codec_registry(&registry)
}

package typed_marshal_test

import "base:runtime"
import "core:io"
import "core:mem"
import "core:testing"
import toml "../.."
import temporal "../../vendor/temporal"
import test_support "../support"

Named_String :: distinct string
Named_Boolean :: distinct bool
Named_Signed :: distinct i32
Named_Unsigned :: distinct u32
Named_Float :: distinct f32
Named_Map_Key :: distinct string

Sequence_Index :: enum {
	First,
	Second,
}

Sequence_Root :: struct {
	fixed:         [2]i32,
	enumerated:    [Sequence_Index]string,
	slice:         []bool,
	dynamic_values: [dynamic]Named_Signed,
}

Map_Field_Root :: struct {
	values: map[Named_Map_Key]i32,
}

Wrapped_Value :: struct {
	value: i32,
}

Optional_Wrapped_Value :: union {
	Wrapped_Value,
}

Optional_Pointer :: union {
	^i32,
}

Optional_Struct_Root :: union {
	Map_Field_Root,
}

Optional_Procedure_Value :: union {
	proc(),
}

General_Union :: union {
	i32,
	string,
}

Wrapper_Root :: struct {
	pointer: ^Wrapped_Value,
	optional: Optional_Wrapped_Value,
	payload: any,
}

Marshal_Node :: struct {
	value: i32,
	next:  ^Marshal_Node `toml:",omitempty"`,
}

Alias_Root :: struct {
	left:  ^Marshal_Node,
	right: ^Marshal_Node,
}

Cycle_Root :: struct {
	node: ^Marshal_Node,
}

Single_Field_Array_Range :: struct {values: [2]u128}
Single_Field_Empty_Fixed_Unsupported :: struct {values: [0]proc()}
Single_Field_Empty_Slice_Unsupported :: struct {values: []proc()}
Single_Field_Empty_Dynamic_Unsupported :: struct {values: [dynamic]proc()}
Single_Field_Empty_Map_Unsupported :: struct {values: map[string]proc()}
Single_Field_Nil_Pointer :: struct {value: ^i32}
Single_Field_Nil_Optional :: struct {value: Optional_Wrapped_Value}
Single_Field_Nil_Any :: struct {value: any}
Single_Field_Nil_Unsupported_Pointer :: struct {value: ^proc()}
Single_Field_Nil_Unsupported_Optional :: struct {value: Optional_Procedure_Value}
Single_Field_Nil_Pure_Maybe :: struct {value: Optional_Pointer}
Single_Field_Nil_Dynamic :: struct {value: [dynamic]i32}
Single_Field_Nil_Map :: struct {value: map[string]i32}
Single_Field_General_Union :: struct {value: General_Union}
Single_Field_Unsupported_Map_Key :: struct {value: map[i32]i32}
Single_Field_Map_Range :: struct {value: map[string]u128}
Single_Field_Any_Map :: struct {value: map[string]any}
Single_Field_Any_Slice :: struct {value: []any}
Single_Field_Empty_Slice :: struct {value: []i32}
Single_Field_Zero_Size_Slice :: struct {value: []struct {}}
Single_Field_Zero_Size_Dynamic :: struct {value: [dynamic]struct {}}
Omit_Pure_Maybe :: struct {
	value: Optional_Pointer `toml:",omitempty"`,
	kept:  i32,
}

Composite_Container_Root :: struct {
	sequence: [3]i32,
	mapping:  map[string]string,
	wrapped:  ^Wrapped_Value,
	payload:  any,
}

Scalar_Root :: struct {
	text:         Named_String,
	enabled:      Named_Boolean,
	signed:       Named_Signed,
	unsigned:     Named_Unsigned,
	ratio:        Named_Float,
	offset:       temporal.Offset_Date_Time,
	local_date:   temporal.Local_Date,
	local_time:   temporal.Local_Time,
	local_stamp:  temporal.Local_Date_Time,
}

Flattened_Fields :: struct {
	second: i32 `toml:"second-name"`,
	third:  string,
}

Named_Using :: struct {
	child: i32,
}

Malformed_After_Unsupported :: struct {
	unsupported: proc(),
	bad: i32 `json:"ok" broken`,
}

Duplicate_Toml_Tag :: struct {
	value: i32 `toml:"first" toml:"second"`,
}

Unknown_Toml_Option :: struct {
	value: i32 `toml:"value,optional"`,
}

Invalid_Ignore_Option :: struct {
	value: i32 `toml:"-,omitempty"`,
}

Invalid_Flatten_Tag :: struct {
	using _: Flattened_Fields `toml:"renamed"`,
}

Scalar_Boundaries :: struct {
	minimum: i128,
	maximum: u64,
	half: f16,
}

Unsupported_Struct :: struct {
	value: proc(),
}

Optional_Procedure :: union {
	Unsupported_Struct,
}

Omit_Empty_States :: struct {
	false_value: bool `toml:",omitempty"`,
	integer_zero: i128 `toml:",omitempty"`,
	float_negative_zero: f64 `toml:",omitempty"`,
	empty_text: string `toml:",omitempty"`,
	empty_array: [0]proc() `toml:",omitempty"`,
	empty_slice: []proc() `toml:",omitempty"`,
	empty_dynamic: [dynamic]proc() `toml:",omitempty"`,
	empty_map: map[string]proc() `toml:",omitempty"`,
	nil_pointer: ^proc() `toml:",omitempty"`,
	nil_optional: Optional_Procedure `toml:",omitempty"`,
	nil_any: any `toml:",omitempty"`,
	kept: i32,
}

Unsupported_Enum :: enum {Value}

Single_Field_Enum :: struct {value: Unsupported_Enum}
Single_Field_Document :: struct {value: toml.Document}
Single_Field_Invalid_Date :: struct {value: temporal.Local_Date}
Single_Field_String :: struct {value: string}
Single_Field_C_String :: struct {value: cstring}
Single_Field_I128 :: struct {value: i128}
Single_Field_U128 :: struct {value: u128}

Depth_Leaf :: struct {value: i32}
Depth_Middle :: struct {leaf: Depth_Leaf}
Depth_Root :: struct {middle: Depth_Middle}

Colliding_Fields :: struct {
	first: i32 `toml:"same"`,
	using _: struct {
		second: i32 `toml:"same"`,
	},
}

Projection_Root :: struct {
	first: i32,
	using _: Flattened_Fields,
	using named: Named_Using,
	empty: string `toml:",omitempty"`,
	ignored: proc() `toml:"-"`,
	last: bool `toml:"renamed"`,
}

@(test)
test_marshal_containers_preserve_declared_sequence_order :: proc(t: ^testing.T) {
	dynamic_values := make([dynamic]Named_Signed)
	defer delete(dynamic_values)
	append(&dynamic_values, 7, 8)
	value := Sequence_Root{
		fixed = {1, 2},
		enumerated = {.First = "first", .Second = "second"},
		slice = []bool{true, false},
		dynamic_values = dynamic_values,
	}
	bytes, err := toml.marshal(value)
	testing.expect(t, err == nil)
	if err != nil {
		return
	}
	defer delete(bytes)
	testing.expect_value(t, string(bytes), `"fixed" = [1, 2]
"enumerated" = ["first", "second"]
"slice" = [true, false]
"dynamic_values" = [7, 8]
`)
}

@(test)
test_marshal_maps_sort_converted_keys_and_support_wrapped_roots :: proc(t: ^testing.T) {
	mapping := make(map[Named_Map_Key]i32)
	defer delete(mapping)
	mapping["é"] = 4
	mapping["a"] = 3
	mapping["A"] = 2
	mapping["0"] = 1

	bytes, err := toml.marshal(Map_Field_Root{values = mapping})
	testing.expect(t, err == nil)
	if err != nil {
		return
	}
	defer delete(bytes)
	testing.expect_value(t, string(bytes), `"values" = { "0" = 1, "A" = 2, "a" = 3, "é" = 4 }
`)

	root_bytes, root_error := toml.marshal(mapping)
	testing.expect(t, root_error == nil)
	if root_error == nil {
		defer delete(root_bytes)
		testing.expect_value(t, string(root_bytes), `"0" = 1
"A" = 2
"a" = 3
"é" = 4
`)
	}

	root_pointer := &mapping
	wrapped_bytes, wrapped_error := toml.marshal(root_pointer)
	testing.expect(t, wrapped_error == nil)
	if wrapped_error == nil {
		defer delete(wrapped_bytes)
		testing.expect_value(t, string(wrapped_bytes), string(root_bytes))
	}

	optional_root: Optional_Struct_Root = Map_Field_Root{values = mapping}
	optional_bytes, optional_error := toml.marshal(optional_root)
	testing.expect(t, optional_error == nil)
	if optional_error == nil {
		defer delete(optional_bytes)
		testing.expect_value(t, string(optional_bytes), string(bytes))
	}

	inner_root: any = Map_Field_Root{values = mapping}
	nested_root := any{&inner_root, typeid_of(any)}
	nested_bytes, nested_error := toml.marshal(nested_root)
	testing.expect(t, nested_error == nil)
	if nested_error == nil {
		defer delete(nested_bytes)
		testing.expect_value(t, string(nested_bytes), string(bytes))
	}
}

@(test)
test_marshal_wrappers_recursively_unwrap_and_nil_states_fail_explicitly :: proc(t: ^testing.T) {
	pointed := Wrapped_Value{value = 1}
	value := Wrapper_Root{
		pointer = &pointed,
		optional = Wrapped_Value{value = 2},
		payload = [2]i32{3, 4},
	}
	bytes, err := toml.marshal(value)
	testing.expect(t, err == nil)
	if err == nil {
		defer delete(bytes)
		testing.expect_value(t, string(bytes), `"pointer" = { "value" = 1 }
"optional" = { "value" = 2 }
"payload" = [3, 4]
`)
	}

	nil_cases := [?]struct {
		value: any,
		source_type: typeid,
	}{
		{Single_Field_Nil_Pointer{}, typeid_of(^i32)},
		{Single_Field_Nil_Optional{}, typeid_of(Optional_Wrapped_Value)},
		{Single_Field_Nil_Any{}, typeid_of(any)},
		{Single_Field_Nil_Unsupported_Pointer{}, typeid_of(^proc())},
		{Single_Field_Nil_Unsupported_Optional{}, typeid_of(Optional_Procedure_Value)},
		{Single_Field_Nil_Pure_Maybe{}, typeid_of(Optional_Pointer)},
	}
	for test_case in nil_cases {
		failed, failure := toml.marshal(test_case.value)
		testing.expect(t, raw_data(failed) == nil)
		data := marshal_data_kind(t, failure)
		testing.expect_value(t, data.kind, toml.Marshal_Data_Error_Kind.Unsupported_Nil)
		testing.expect_value(t, data.source_type, test_case.source_type)
	}

	unsupported, unsupported_error := toml.marshal(
		Single_Field_General_Union{value = i32(1)},
	)
	testing.expect(t, raw_data(unsupported) == nil)
	data := marshal_data_kind(t, unsupported_error)
	testing.expect_value(t, data.kind, toml.Marshal_Data_Error_Kind.Unsupported_Type)
	testing.expect_value(t, data.source_type, typeid_of(General_Union))
}

@(test)
test_marshal_validates_empty_declared_types_and_container_initialization :: proc(t: ^testing.T) {
	empty_dynamic := make([dynamic]proc())
	defer delete(empty_dynamic)
	empty_map := make(map[string]proc())
	defer delete(empty_map)
	unsupported_cases := [?]any{
		Single_Field_Empty_Fixed_Unsupported{},
		Single_Field_Empty_Slice_Unsupported{},
		Single_Field_Empty_Dynamic_Unsupported{values = empty_dynamic},
		Single_Field_Empty_Map_Unsupported{values = empty_map},
	}
	for value in unsupported_cases {
		failed, failure := toml.marshal(value)
		testing.expect(t, raw_data(failed) == nil)
		data := marshal_data_kind(t, failure)
		testing.expect_value(t, data.kind, toml.Marshal_Data_Error_Kind.Unsupported_Type)
		testing.expect_value(t, data.source_type, typeid_of(proc()))
	}

	invalid_cases := [?]any{
		Single_Field_Nil_Dynamic{},
		Single_Field_Nil_Map{},
	}
	for value in invalid_cases {
		failed, failure := toml.marshal(value)
		testing.expect(t, raw_data(failed) == nil)
		data := marshal_data_kind(t, failure)
		testing.expect_value(t, data.kind, toml.Marshal_Data_Error_Kind.Invalid_Container)
	}
}

@(test)
test_marshal_reports_container_value_paths_and_active_cycles :: proc(t: ^testing.T) {
	failed, failure := toml.marshal(Single_Field_Array_Range{values = {1, u128(max(i64))+1}})
	testing.expect(t, raw_data(failed) == nil)
	diagnostic, ok := failure.(toml.Marshal_Diagnostic)
	testing.expect(t, ok)
	if ok {
		data, data_ok := diagnostic.detail.(toml.Marshal_Data_Error)
		testing.expect(t, data_ok)
		if data_ok {
			testing.expect_value(t, data.kind, toml.Marshal_Data_Error_Kind.Integer_Out_Of_Range)
			testing.expect_value(t, data.source_type, typeid_of(u128))
		}
		name, name_ok := diagnostic.path.segments[0].(string)
		index, index_ok := diagnostic.path.segments[1].(toml.Path_Index)
		testing.expect(t, name_ok)
		testing.expect(t, index_ok)
		if name_ok {
			testing.expect_value(t, name, "values")
		}
		if index_ok {
			testing.expect_value(t, index, toml.Path_Index(1))
		}
		testing.expect_value(t, diagnostic.path.total_segment_count, u16(2))
	}

	shared := Marshal_Node{value = 5}
	aliases, alias_error := toml.marshal(Alias_Root{left = &shared, right = &shared})
	testing.expect(t, alias_error == nil)
	if alias_error == nil {
		defer delete(aliases)
		testing.expect_value(t, string(aliases), `"left" = { "value" = 5 }
"right" = { "value" = 5 }
`)
	}

	cyclic := Marshal_Node{value = 7}
	cyclic.next = &cyclic
	cycle_bytes, cycle_error := toml.marshal(Cycle_Root{node = &cyclic})
	testing.expect(t, raw_data(cycle_bytes) == nil)
	cycle_diagnostic, cycle_ok := cycle_error.(toml.Marshal_Diagnostic)
	testing.expect(t, cycle_ok)
	if cycle_ok {
		data, data_ok := cycle_diagnostic.detail.(toml.Marshal_Data_Error)
		testing.expect(t, data_ok)
		if data_ok {
			testing.expect_value(t, data.kind, toml.Marshal_Data_Error_Kind.Active_Recursion_Cycle)
			testing.expect_value(t, data.source_type, typeid_of(^Marshal_Node))
		}
		testing.expect_value(t, cycle_diagnostic.path.total_segment_count, u16(2))
	}
}

@(test)
test_marshal_map_diagnostics_are_sorted_and_cycles_track_only_active_references :: proc(t: ^testing.T) {
	unsupported_map := make(map[i32]i32)
	defer delete(unsupported_map)
	unsupported, unsupported_error := toml.marshal(
		Single_Field_Unsupported_Map_Key{value = unsupported_map},
	)
	testing.expect(t, raw_data(unsupported) == nil)
	data := marshal_data_kind(t, unsupported_error)
	testing.expect_value(t, data.kind, toml.Marshal_Data_Error_Kind.Unsupported_Map_Key_Type)
	testing.expect_value(t, data.source_type, typeid_of(i32))

	ranges := make(map[string]u128)
	defer delete(ranges)
	ranges["z"] = u128(max(i64))+1
	ranges["a"] = u128(max(i64))+2
	failed, failure := toml.marshal(Single_Field_Map_Range{value = ranges})
	testing.expect(t, raw_data(failed) == nil)
	diagnostic, ok := failure.(toml.Marshal_Diagnostic)
	testing.expect(t, ok)
	if ok {
		value_name, value_name_ok := diagnostic.path.segments[0].(string)
		key_name, key_name_ok := diagnostic.path.segments[1].(string)
		testing.expect(t, value_name_ok)
		testing.expect(t, key_name_ok)
		if value_name_ok {
			testing.expect_value(t, value_name, "value")
		}
		if key_name_ok {
			testing.expect_value(t, key_name, "a")
		}
	}

	self_map := make(map[string]any)
	defer delete(self_map)
	self_map["self"] = self_map
	cycle_bytes, cycle_error := toml.marshal(Single_Field_Any_Map{value = self_map})
	testing.expect(t, raw_data(cycle_bytes) == nil)
	data = marshal_data_kind(t, cycle_error)
	testing.expect_value(t, data.kind, toml.Marshal_Data_Error_Kind.Active_Recursion_Cycle)
	testing.expect_value(t, data.source_type, typeid_of(map[string]any))

	self_slice, slice_error := make([]any, 1)
	assert(slice_error == nil)
	defer delete(self_slice)
	self_slice[0] = self_slice
	cycle_bytes, cycle_error = toml.marshal(Single_Field_Any_Slice{value = self_slice})
	testing.expect(t, raw_data(cycle_bytes) == nil)
	data = marshal_data_kind(t, cycle_error)
	testing.expect_value(t, data.kind, toml.Marshal_Data_Error_Kind.Active_Recursion_Cycle)
	testing.expect_value(t, data.source_type, typeid_of([]any))

	cyclic_any: any
	cyclic_any = any{&cyclic_any, typeid_of(any)}
	cycle_bytes, cycle_error = toml.marshal(struct {value: any}{value = cyclic_any})
	testing.expect(t, raw_data(cycle_bytes) == nil)
	data = marshal_data_kind(t, cycle_error)
	testing.expect_value(t, data.kind, toml.Marshal_Data_Error_Kind.Active_Recursion_Cycle)
	testing.expect_value(t, data.source_type, typeid_of(any))

	invalid_high := [1]byte{0xff}
	invalid_low := [1]byte{0x80}
	invalid_keys := make(map[string]i32)
	defer delete(invalid_keys)
	invalid_keys[string(invalid_high[:])] = 2
	invalid_keys[string(invalid_low[:])] = 1
	invalid_bytes, invalid_error := toml.marshal(
		struct {value: map[string]i32}{value = invalid_keys},
	)
	testing.expect(t, raw_data(invalid_bytes) == nil)
	invalid_diagnostic, invalid_ok := invalid_error.(toml.Marshal_Diagnostic)
	testing.expect(t, invalid_ok)
	if invalid_ok {
		invalid_data, data_ok := invalid_diagnostic.detail.(toml.Marshal_Data_Error)
		testing.expect(t, data_ok)
		if data_ok {
			testing.expect_value(t, invalid_data.kind, toml.Marshal_Data_Error_Kind.Invalid_Text)
			testing.expect_value(t, invalid_data.source_type, typeid_of(string))
		}
		invalid_key, key_ok := invalid_diagnostic.path.segments[1].(string)
		testing.expect(t, key_ok)
		if key_ok {
			testing.expect_value(t, invalid_key, string(invalid_low[:]))
		}
	}

	nil_slice_bytes, nil_slice_error := toml.marshal(Single_Field_Empty_Slice{})
	testing.expect(t, nil_slice_error == nil)
	if nil_slice_error == nil {
		defer delete(nil_slice_bytes)
		testing.expect_value(t, string(nil_slice_bytes), `"value" = []
`)
	}

	zero_size, zero_size_error := make([]struct {}, 2)
	assert(zero_size_error == nil)
	defer delete(zero_size)
	zero_size_bytes, zero_size_marshal_error := toml.marshal(
		Single_Field_Zero_Size_Slice{value = zero_size},
	)
	testing.expect(t, zero_size_marshal_error == nil)
	if zero_size_marshal_error == nil {
		defer delete(zero_size_bytes)
		testing.expect_value(t, string(zero_size_bytes), `"value" = [{}, {}]
`)
	}

	zero_dynamic := make([dynamic]struct {})
	defer delete(zero_dynamic)
	append(&zero_dynamic, struct {}{}, struct {}{})
	zero_dynamic_bytes, zero_dynamic_error := toml.marshal(
		Single_Field_Zero_Size_Dynamic{value = zero_dynamic},
	)
	testing.expect(t, zero_dynamic_error == nil)
	if zero_dynamic_error == nil {
		defer delete(zero_dynamic_bytes)
		testing.expect_value(t, string(zero_dynamic_bytes), `"value" = [{}, {}]
`)
	}

	overlap, overlap_error := make([]any, 2)
	assert(overlap_error == nil)
	defer delete(overlap)
	overlap[0] = i32(1)
	overlap[1] = overlap[:1]
	overlap_bytes, overlap_marshal_error := toml.marshal(
		Single_Field_Any_Slice{value = overlap},
	)
	testing.expect(t, overlap_marshal_error == nil)
	if overlap_marshal_error == nil {
		defer delete(overlap_bytes)
		testing.expect_value(t, string(overlap_bytes), `"value" = [1, [1]]
`)
	}

	wrapper_chain: [300]any
	wrapper_chain[len(wrapper_chain)-1] = struct {}{}
	for index := len(wrapper_chain)-2; index >= 0; index -= 1 {
		wrapper_chain[index] = any{&wrapper_chain[index+1], typeid_of(any)}
	}
	chain_bytes, chain_error := toml.marshal(
		struct {value: any}{value = wrapper_chain[0]},
	)
	testing.expect(t, chain_error == nil)
	if chain_error == nil {
		defer delete(chain_bytes)
		testing.expect_value(t, string(chain_bytes), `"value" = {}
`)
	}
}

@(test)
test_marshal_container_writer_identity_preflight_and_failed_allocation_cleanup :: proc(t: ^testing.T) {
	mapping := make(map[string]string)
	defer delete(mapping)
	mapping["b"] = "second"
	mapping["a"] = "first"
	wrapped := Wrapped_Value{value = 9}
	value := Composite_Container_Root{
		sequence = {1, 2, 3},
		mapping = mapping,
		wrapped = &wrapped,
		payload = []bool{true, false},
	}

	backing := context.allocator
	success_events: [1024]test_support.Allocator_Event
	success_live: [256]test_support.Live_Allocation
	success: test_support.Observed_Allocator
	test_support.observed_allocator_init(&success, backing, success_events[:], success_live[:])
	selected := test_support.observed_allocator(&success)
	bytes, err := toml.marshal(value, allocator = selected)
	assert(err == nil)
	allocation_count := success.allocation_request_count
	testing.expect_value(t, success.live_count, 1)

	options: toml.Marshal_Options
	calls: [256]test_support.Scripted_Writer_Call
	requested: [4096]byte
	writer_state: test_support.Scripted_Writer
	test_support.scripted_writer_init(&writer_state, nil, calls[:], requested[:])
	writer_error := toml.marshal_to_writer(
		test_support.scripted_writer(&writer_state),
		value,
		&options,
		selected,
	)
	testing.expect(t, writer_error == nil)
	testing.expect_value(t, string(requested[:writer_state.byte_count]), string(bytes))
	writer_allocation_count := success.allocation_request_count-allocation_count
	delete(bytes, selected)
	testing.expect_value(t, success.live_count, 0)

	for fail_at in 1..=allocation_count {
		events: [1024]test_support.Allocator_Event
		live: [256]test_support.Live_Allocation
		state: test_support.Observed_Allocator
		test_support.observed_allocator_init(&state, backing, events[:], live[:])
		state.fail_at_allocation = fail_at
		state.failure_error = .Out_Of_Memory
		failed, failure := toml.marshal(
			value,
			allocator = test_support.observed_allocator(&state),
		)
		testing.expect(t, raw_data(failed) == nil)
		allocator_error, ok := failure.(runtime.Allocator_Error)
		testing.expect(t, ok)
		if ok {
			testing.expect_value(t, allocator_error, runtime.Allocator_Error.Out_Of_Memory)
		}
		testing.expect_value(t, state.live_count, 0)
		testing.expect_value(t, state.foreign_release_count, 0)
	}

	for fail_at in 1..=writer_allocation_count {
		events: [1024]test_support.Allocator_Event
		live: [256]test_support.Live_Allocation
		state: test_support.Observed_Allocator
		test_support.observed_allocator_init(&state, backing, events[:], live[:])
		state.fail_at_allocation = fail_at
		state.failure_error = .Out_Of_Memory
		test_support.scripted_writer_init(&writer_state, nil, calls[:], requested[:])
		failure := toml.marshal_to_writer(
			test_support.scripted_writer(&writer_state),
			value,
			&options,
			test_support.observed_allocator(&state),
		)
		allocator_error, ok := failure.(runtime.Allocator_Error)
		testing.expect(t, ok)
		if ok {
			testing.expect_value(t, allocator_error, runtime.Allocator_Error.Out_Of_Memory)
		}
		testing.expect_value(t, writer_state.write_count, 0)
		testing.expect_value(t, state.live_count, 0)
		testing.expect_value(t, state.foreign_release_count, 0)
	}

	self_map := make(map[string]any)
	defer delete(self_map)
	self_map["self"] = self_map
	test_support.scripted_writer_init(&writer_state, nil, calls[:], requested[:])
	preflight_error := toml.marshal_to_writer(
		test_support.scripted_writer(&writer_state),
		Single_Field_Any_Map{value = self_map},
		&options,
	)
	data := marshal_data_kind(t, preflight_error)
	testing.expect_value(t, data.kind, toml.Marshal_Data_Error_Kind.Active_Recursion_Cycle)
	testing.expect_value(t, writer_state.write_count, 0)
}

@(test)
test_marshal_rejects_non_struct_roots :: proc(t: ^testing.T) {
	root_cases := [?]any{
		i32(1),
		"text",
		temporal.Local_Date{2024, 1, 1},
		[1]i32{1},
		[]i32{1},
		toml.Document{},
	}
	for value in root_cases {
		bytes, err := toml.marshal(value)
		testing.expect(t, raw_data(bytes) == nil)
		if raw_data(bytes) != nil {
			delete(bytes)
		}
		data := marshal_data_kind(t, err)
		testing.expect_value(t, data.kind, toml.Marshal_Data_Error_Kind.Invalid_Root_Shape)
	}

	nil_value: any
	bytes, err := toml.marshal(nil_value)
	testing.expect(t, raw_data(bytes) == nil)
	data := marshal_data_kind(t, err)
	testing.expect_value(t, data.kind, toml.Marshal_Data_Error_Kind.Unsupported_Nil)
}

@(test)
test_marshal_struct_scalars_match_semantic_canonical_bytes :: proc(t: ^testing.T) {
	value := Scalar_Root{
		text = "hello",
		enabled = true,
		signed = -42,
		unsigned = 43,
		ratio = 1.5,
		offset = {
			local = {date = {2026, 7, 22}, time = {9, 30, 0, 0}},
			offset = {.Known, 90},
		},
		local_date = {2024, 2, 29},
		local_time = {23, 59, 60, 120_000_000},
		local_stamp = {
			date = {2000, 1, 2},
			time = {3, 4, 5, 6},
		},
	}

	actual, err := toml.marshal(value)
	testing.expect(t, err == nil)
	if err != nil {
		return
	}
	defer delete(actual)

	doc, parse_error := toml.parse_string(`text = "hello"
enabled = true
signed = -42
unsigned = 43
ratio = 1.5
offset = 2026-07-22T09:30:00+01:30
local_date = 2024-02-29
local_time = 23:59:60.12
local_stamp = 2000-01-02T03:04:05.000000006
`)
	assert(parse_error == nil)
	defer toml.destroy_document(&doc)
	expected, unparse_error := toml.unparse(&doc)
	assert(unparse_error == nil)
	defer delete(expected)

	testing.expect_value(t, string(actual), expected)
}

@(test)
test_marshal_projects_tags_using_fields_omission_and_ignore_in_declaration_order :: proc(t: ^testing.T) {
	value := Projection_Root{
		first = 1,
		second = 2,
		third = "three",
		named = {child = 4},
		empty = "",
		ignored = proc() {},
		last = true,
	}
	actual, err := toml.marshal(value)
	testing.expect(t, err == nil)
	if err != nil {
		return
	}
	defer delete(actual)
	testing.expect_value(t, string(actual), `"first" = 1
"second-name" = 2
"third" = "three"
"named" = { "child" = 4 }
"renamed" = true
`)
}

marshal_data_kind :: proc(t: ^testing.T, err: toml.Marshal_Error) -> toml.Marshal_Data_Error {
	diagnostic, diagnostic_ok := err.(toml.Marshal_Diagnostic)
	testing.expect(t, diagnostic_ok)
	if !diagnostic_ok {
		return {}
	}
	data, data_ok := diagnostic.detail.(toml.Marshal_Data_Error)
	testing.expect(t, data_ok)
	if !data_ok {
		return {}
	}
	if data.kind != .Invalid_Temporal {
		testing.expect_value(t, data.temporal_error, temporal.Error.None)
	}
	if data.kind != .Effective_Field_Name_Collision {
		testing.expect(t, data.related_type == nil)
	}
	testing.expect_value(t, data.expected_count, 0)
	testing.expect_value(t, data.actual_count, 0)
	if diagnostic.path.total_segment_count <= 32 {
		testing.expect_value(t, diagnostic.path.segment_count, u8(diagnostic.path.total_segment_count))
		testing.expect_value(t, diagnostic.path.prefix_count, u8(diagnostic.path.total_segment_count))
		testing.expect_value(t, diagnostic.path.omitted_segment_count, u16(0))
		testing.expect(t, !diagnostic.path.truncated)
	} else {
		testing.expect_value(t, diagnostic.path.segment_count, u8(32))
		testing.expect_value(t, diagnostic.path.prefix_count, u8(8))
		testing.expect_value(
			t, diagnostic.path.omitted_segment_count,
			diagnostic.path.total_segment_count-32,
		)
		testing.expect(t, diagnostic.path.truncated)
	}
	return data
}

@(test)
test_marshal_checks_scalar_boundaries_and_reports_value_paths :: proc(t: ^testing.T) {
	valid := Scalar_Boundaries{
		minimum = i128(min(i64)),
		maximum = u64(max(i64)),
		half = 0.5,
	}
	bytes, err := toml.marshal(valid)
	testing.expect(t, err == nil)
	if err == nil {
		defer delete(bytes)
		testing.expect_value(t, string(bytes), `"minimum" = -9223372036854775808
"maximum" = 9223372036854775807
"half" = 0.5
`)
	}

	integer_cases := [?]any{
		Single_Field_I128{value = i128(max(i64))+1},
		Single_Field_U128{value = u128(max(i64))+1},
	}
	for value in integer_cases {
		failed, failure := toml.marshal(value)
		testing.expect(t, raw_data(failed) == nil)
		data := marshal_data_kind(t, failure)
		testing.expect_value(t, data.kind, toml.Marshal_Data_Error_Kind.Integer_Out_Of_Range)
	}

	unsupported, unsupported_error := toml.marshal(Single_Field_Enum{})
	testing.expect(t, raw_data(unsupported) == nil)
	data := marshal_data_kind(t, unsupported_error)
	testing.expect_value(t, data.kind, toml.Marshal_Data_Error_Kind.Unsupported_Type)

	unsupported, unsupported_error = toml.marshal(Single_Field_Document{})
	testing.expect(t, raw_data(unsupported) == nil)
	data = marshal_data_kind(t, unsupported_error)
	testing.expect_value(t, data.kind, toml.Marshal_Data_Error_Kind.Unsupported_Type)
	testing.expect_value(t, data.source_type, typeid_of(toml.Document))

	invalid, invalid_error := toml.marshal(Single_Field_Invalid_Date{value = {2024, 2, 30}})
	testing.expect(t, raw_data(invalid) == nil)
	data = marshal_data_kind(t, invalid_error)
	testing.expect_value(t, data.kind, toml.Marshal_Data_Error_Kind.Invalid_Temporal)
	testing.expect_value(t, data.temporal_error, temporal.Error.Invalid_Day)

	invalid_bytes := [1]byte{0xff}
	invalid, invalid_error = toml.marshal(Single_Field_String{value = string(invalid_bytes[:])})
	testing.expect(t, raw_data(invalid) == nil)
	data = marshal_data_kind(t, invalid_error)
	testing.expect_value(t, data.kind, toml.Marshal_Data_Error_Kind.Invalid_Text)

	unsupported, unsupported_error = toml.marshal(Single_Field_C_String{value = cstring("text")})
	testing.expect(t, raw_data(unsupported) == nil)
	data = marshal_data_kind(t, unsupported_error)
	testing.expect_value(t, data.kind, toml.Marshal_Data_Error_Kind.Unsupported_Type)

	too_deep, depth_error := toml.marshal(
		Depth_Root{middle = {leaf = {value = 1}}},
		{max_depth = 2},
	)
	testing.expect(t, raw_data(too_deep) == nil)
	depth_diagnostic, depth_ok := depth_error.(toml.Marshal_Diagnostic)
	testing.expect(t, depth_ok)
	if depth_ok {
		limit, limit_ok := depth_diagnostic.detail.(toml.Marshal_Limit_Error)
		testing.expect(t, limit_ok)
		if limit_ok {
			testing.expect_value(t, limit, toml.Marshal_Limit_Error.Maximum_Depth_Exceeded)
		}
		testing.expect_value(t, depth_diagnostic.path.total_segment_count, u16(3))
	}
}

@(test)
test_marshal_omitempty_uses_the_frozen_finite_empty_set :: proc(t: ^testing.T) {
	bytes, err := toml.marshal(Omit_Empty_States{kept = 7})
	testing.expect(t, err == nil)
	if err != nil {
		return
	}
	defer delete(bytes)
	testing.expect_value(t, string(bytes), `"kept" = 7
`)

	pure_maybe_bytes, pure_maybe_error := toml.marshal(Omit_Pure_Maybe{kept = 8})
	testing.expect(t, pure_maybe_error == nil)
	if pure_maybe_error == nil {
		defer delete(pure_maybe_bytes)
		testing.expect_value(t, string(pure_maybe_bytes), `"kept" = 8
`)
	}
}

@(test)
test_marshal_writer_matches_allocated_output_and_preflights_before_writing :: proc(t: ^testing.T) {
	value := Projection_Root{
		first = 1,
		second = 2,
		third = "three",
		named = {child = 4},
		last = true,
	}
	allocated, allocated_error := toml.marshal(value)
	assert(allocated_error == nil)
	defer delete(allocated)

	calls: [128]test_support.Scripted_Writer_Call
	requested: [2048]byte
	state: test_support.Scripted_Writer
	test_support.scripted_writer_init(&state, nil, calls[:], requested[:])
	options: toml.Marshal_Options
	writer_error := toml.marshal_to_writer(
		test_support.scripted_writer(&state),
		value,
		&options,
	)
	testing.expect(t, writer_error == nil)
	testing.expect_value(t, string(requested[:state.byte_count]), string(allocated))

	test_support.scripted_writer_init(&state, nil, calls[:], requested[:])
	writer_error = toml.marshal_to_writer(
		test_support.scripted_writer(&state),
		Malformed_After_Unsupported{},
		&options,
	)
	data := marshal_data_kind(t, writer_error)
	testing.expect_value(t, data.kind, toml.Marshal_Data_Error_Kind.Malformed_Tag)
	testing.expect_value(t, state.write_count, 0)

	empty, empty_error := toml.marshal(struct {}{})
	testing.expect(t, empty_error == nil)
	testing.expect(t, raw_data(empty) == nil)
	test_support.scripted_writer_init(&state, nil, calls[:], requested[:])
	writer_error = toml.marshal_to_writer(
		test_support.scripted_writer(&state),
		struct {}{},
		&options,
	)
	testing.expect(t, writer_error == nil)
	testing.expect_value(t, state.write_count, 0)
}

@(test)
test_marshal_configuration_precedence_makes_no_writer_calls :: proc(t: ^testing.T) {
	calls: [8]test_support.Scripted_Writer_Call
	requested: [64]byte
	state: test_support.Scripted_Writer
	writer := test_support.scripted_writer(&state)
	nil_allocator: mem.Allocator
	invalid_depth := toml.Marshal_Options{max_depth = -1}

	test_support.scripted_writer_init(&state, nil, calls[:], requested[:])
	err := toml.marshal_to_writer(writer, struct {}{}, nil, nil_allocator)
	configuration, ok := err.(toml.Marshal_Configuration_Error)
	testing.expect(t, ok)
	if ok {
		testing.expect_value(t, configuration, toml.Marshal_Configuration_Error.Invalid_Allocator)
	}
	testing.expect_value(t, state.write_count, 0)

	test_support.scripted_writer_init(&state, nil, calls[:], requested[:])
	err = toml.marshal_to_writer(writer, struct {}{}, nil)
	configuration, ok = err.(toml.Marshal_Configuration_Error)
	testing.expect(t, ok)
	if ok {
		testing.expect_value(t, configuration, toml.Marshal_Configuration_Error.Nil_Options)
	}
	testing.expect_value(t, state.write_count, 0)

	test_support.scripted_writer_init(&state, nil, calls[:], requested[:])
	err = toml.marshal_to_writer(writer, struct {}{}, &invalid_depth)
	configuration, ok = err.(toml.Marshal_Configuration_Error)
	testing.expect(t, ok)
	if ok {
		testing.expect_value(t, configuration, toml.Marshal_Configuration_Error.Invalid_Max_Depth)
	}
	testing.expect_value(t, state.write_count, 0)

}

@(test)
test_marshal_cleans_every_failed_allocation_ordinal :: proc(t: ^testing.T) {
	value := Scalar_Root{
		text = "allocation",
		enabled = true,
		signed = -42,
		unsigned = 43,
		ratio = 1.5,
		offset = {
			local = {date = {2026, 7, 22}, time = {9, 30, 0, 0}},
			offset = {.Known, 0},
		},
		local_date = {2024, 2, 29},
		local_time = {1, 2, 3, 4},
		local_stamp = {date = {2000, 1, 2}, time = {3, 4, 5, 6}},
	}
	backing := context.allocator
	success_events: [512]test_support.Allocator_Event
	success_live: [128]test_support.Live_Allocation
	success: test_support.Observed_Allocator
	test_support.observed_allocator_init(&success, backing, success_events[:], success_live[:])
	selected := test_support.observed_allocator(&success)
	rejecting: test_support.Rejecting_Allocator
	context.allocator = test_support.rejecting_allocator(&rejecting)
	bytes, err := toml.marshal(value, allocator = selected)
	context.allocator = backing
	assert(err == nil)
	testing.expect_value(t, success.live_count, 1)
	testing.expect_value(t, rejecting.allocation_attempt_count, 0)
	allocation_count := success.allocation_request_count
	delete(bytes, selected)
	testing.expect_value(t, success.live_count, 0)

	for fail_at in 1..=allocation_count {
		events: [512]test_support.Allocator_Event
		live: [128]test_support.Live_Allocation
		state: test_support.Observed_Allocator
		test_support.observed_allocator_init(&state, backing, events[:], live[:])
		state.fail_at_allocation = fail_at
		state.failure_error = .Out_Of_Memory
		failed, failure := toml.marshal(
			value,
			allocator = test_support.observed_allocator(&state),
		)
		testing.expect(t, raw_data(failed) == nil)
		allocator_error, ok := failure.(runtime.Allocator_Error)
		testing.expect(t, ok)
		if ok {
			testing.expect_value(t, allocator_error, runtime.Allocator_Error.Out_Of_Memory)
		}
		testing.expect_value(t, state.live_count, 0)
		testing.expect_value(t, state.foreign_release_count, 0)
	}

	options: toml.Marshal_Options
	baseline_events: [512]test_support.Allocator_Event
	baseline_live: [128]test_support.Live_Allocation
	baseline_allocator: test_support.Observed_Allocator
	test_support.observed_allocator_init(
		&baseline_allocator,
		backing,
		baseline_events[:],
		baseline_live[:],
	)
	calls: [128]test_support.Scripted_Writer_Call
	requested: [4096]byte
	writer_state: test_support.Scripted_Writer
	test_support.scripted_writer_init(&writer_state, nil, calls[:], requested[:])
	writer_error := toml.marshal_to_writer(
		test_support.scripted_writer(&writer_state),
		value,
		&options,
		test_support.observed_allocator(&baseline_allocator),
	)
	assert(writer_error == nil)
	assert(baseline_allocator.live_count == 0)
	writer_allocation_count := baseline_allocator.allocation_request_count
	for fail_at in 1..=writer_allocation_count {
		events: [512]test_support.Allocator_Event
		live: [128]test_support.Live_Allocation
		state: test_support.Observed_Allocator
		test_support.observed_allocator_init(&state, backing, events[:], live[:])
		state.fail_at_allocation = fail_at
		state.failure_error = .Out_Of_Memory
		test_support.scripted_writer_init(&writer_state, nil, calls[:], requested[:])
		failure := toml.marshal_to_writer(
			test_support.scripted_writer(&writer_state),
			value,
			&options,
			test_support.observed_allocator(&state),
		)
		allocator_error, ok := failure.(runtime.Allocator_Error)
		testing.expect(t, ok)
		if ok {
			testing.expect_value(t, allocator_error, runtime.Allocator_Error.Out_Of_Memory)
		}
		testing.expect_value(t, writer_state.write_count, 0)
		testing.expect_value(t, state.live_count, 0)
		testing.expect_value(t, state.foreign_release_count, 0)
	}
}

@(test)
test_marshal_writer_preserves_common_fault_contract_and_cleanup :: proc(t: ^testing.T) {
	value := Projection_Root{
		first = 1,
		second = 2,
		third = "three",
		named = {child = 4},
		last = true,
	}
	canonical, canonical_error := toml.marshal(value)
	assert(canonical_error == nil)
	defer delete(canonical)
	options: toml.Marshal_Options
	cases := [?]struct {
		step: test_support.Scripted_Write,
		expected: io.Error,
	}{
		{{count_kind = .Exact, count = 0}, .Short_Write},
		{{count_kind = .Negative}, .Invalid_Write},
		{{count_kind = .Past_End}, .Invalid_Write},
		{{count_kind = .Exact, count = 1, error = .Permission_Denied}, .Permission_Denied},
	}
	for test_case in cases {
		steps := [1]test_support.Scripted_Write{test_case.step}
		calls: [64]test_support.Scripted_Writer_Call
		requested: [1024]byte
		writer_state: test_support.Scripted_Writer
		test_support.scripted_writer_init(&writer_state, steps[:], calls[:], requested[:])
		events: [512]test_support.Allocator_Event
		live: [128]test_support.Live_Allocation
		allocator_state: test_support.Observed_Allocator
		test_support.observed_allocator_init(&allocator_state, context.allocator, events[:], live[:])
		err := toml.marshal_to_writer(
			test_support.scripted_writer(&writer_state),
			value,
			&options,
			test_support.observed_allocator(&allocator_state),
		)
		writer_error, ok := err.(io.Error)
		testing.expect(t, ok)
		if ok {
			testing.expect_value(t, writer_error, test_case.expected)
		}
		testing.expect_value(t, writer_state.write_count, 1)
		testing.expect_value(t, allocator_state.live_count, 0)
		testing.expect_value(t, allocator_state.foreign_release_count, 0)
		accepted := 0
		if test_case.step.count_kind == .Exact &&
		   0 <= test_case.step.count && test_case.step.count <= i64(calls[0].requested_count) {
			accepted = int(test_case.step.count)
		}
		testing.expect_value(
			t,
			string(requested[:accepted]),
			string(canonical[:accepted]),
		)
	}
}

@(test)
test_marshal_validates_complete_tags_and_collisions_before_field_values :: proc(t: ^testing.T) {
	malformed_cases := [?]any{
		Malformed_After_Unsupported{},
		Duplicate_Toml_Tag{},
		Unknown_Toml_Option{},
		Invalid_Ignore_Option{},
		Invalid_Flatten_Tag{},
	}
	for value in malformed_cases {
		bytes, err := toml.marshal(value)
		testing.expect(t, raw_data(bytes) == nil)
		data := marshal_data_kind(t, err)
		testing.expect_value(t, data.kind, toml.Marshal_Data_Error_Kind.Malformed_Tag)
	}

	bytes, err := toml.marshal(Colliding_Fields{})
	testing.expect(t, raw_data(bytes) == nil)
	data := marshal_data_kind(t, err)
	testing.expect_value(
		t,
		data.kind,
		toml.Marshal_Data_Error_Kind.Effective_Field_Name_Collision,
	)
	testing.expect_value(t, data.source_type, typeid_of(i32))
	testing.expect_value(t, data.related_type, typeid_of(i32))
}

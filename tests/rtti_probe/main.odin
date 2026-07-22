package rtti_probe

import "base:runtime"
import "core:mem"
import "core:reflect"
import "../../vendor/temporal"
import support "../support"

Embedded :: struct {
	flattened: i32 `toml:"flattened_name"`,
}

Reflection_Destination :: struct {
	first: i32 `toml:"first_name"`,
	using _: Embedded,
	last: string `toml:"last_name,omitempty"`,
}

Distinct_String :: distinct string
Distinct_Integer :: distinct i32
Distinct_Float :: distinct f64
Distinct_Boolean :: distinct bool
Alias_Integer :: i32

Temporal_Lookalike :: struct {
	year:  u16,
	month: u8,
	day:   u8,
}

Wrapper_Value :: struct {
	value: i32,
}

Optional_Wrapper :: union {
	Wrapper_Value,
}

Wrapper_Destination :: struct {
	pointer:  ^Wrapper_Value,
	optional: Optional_Wrapper,
}

Container_Destination :: struct {
	mapping: map[string]i32,
	values:  []i32,
	items:   [dynamic]i32,
}

Cycle_Node :: struct {
	next: ^Cycle_Node,
}

Aligned_Empty :: struct #align(64) {}

Unsupported_Enum :: enum {
	Value,
}

Unsupported_Procedure :: proc()

main :: proc() {
	probe_struct_reflection_and_destination_any()
	probe_exact_type_identity()
	probe_binding_type_metadata()
	probe_omitempty_inputs()
	probe_cycle_identity()
	probe_optional_union_and_wrapper_destinations()
	probe_allocator_controlled_container_installation()
	probe_aligned_zero_size_pointee_installation()
}

probe_struct_reflection_and_destination_any :: proc() {
	fields := reflect.struct_fields_zipped(Reflection_Destination)
	assert(len(fields) == 3)

	expected_names := [3]string{"first", "_", "last"}
	expected_tags := [3]string{"first_name", "", "last_name,omitempty"}
	expected_tag_presence := [3]bool{true, false, true}
	expected_using := [3]bool{false, true, false}
	for field, index in fields {
		assert(field.name == expected_names[index])
		tag, ok := reflect.struct_tag_lookup(field.tag, "toml")
		assert(ok == expected_tag_presence[index])
		assert(tag == expected_tags[index])
		assert(field.is_using == expected_using[index])
	}

	embedded_fields := reflect.struct_fields_zipped(fields[1].type.id)
	assert(len(embedded_fields) == 1)
	assert(embedded_fields[0].name == "flattened")
	flattened_tag, flattened_tag_ok := reflect.struct_tag_lookup(embedded_fields[0].tag, "toml")
	assert(flattened_tag_ok)
	assert(flattened_tag == "flattened_name")

	destination: Reflection_Destination
	first := reflect.struct_field_value(destination, fields[0])
	assert(first.id == typeid_of(i32))
	switch &value in first {
	case i32:
		value = 41
	case:
		assert(false)
	}
	assert(destination.first == 41)

	embedded := reflect.struct_field_value(destination, fields[1])
	flattened := reflect.struct_field_value(embedded, embedded_fields[0])
	switch &value in flattened {
	case i32:
		value = 42
	case:
		assert(false)
	}
	assert(destination.flattened == 42)
}

probe_exact_type_identity :: proc() {
	distinct_value := Distinct_String("value")
	distinct_any: any = distinct_value
	assert(distinct_any.id == typeid_of(Distinct_String))
	assert(distinct_any.id != typeid_of(string))
	assert(reflect.type_kind(distinct_any.id) == .Named)
	assert(reflect.underlying_type_kind(distinct_any.id) == .String)

	base_any := reflect.any_base(distinct_any)
	assert(base_any.id == typeid_of(string))
	assert(base_any.data == distinct_any.data)

	assert(typeid_of(Alias_Integer) == typeid_of(i32))
	assert(typeid_of(Distinct_Integer) != typeid_of(i32))
	assert(reflect.underlying_type_kind(typeid_of(Distinct_Float)) == .Float)
	assert(reflect.underlying_type_kind(typeid_of(Distinct_Boolean)) == .Boolean)
	assert(typeid_of(temporal.Local_Date) != typeid_of(Temporal_Lookalike))

	lookup := make(map[typeid]int)
	defer delete(lookup)
	lookup[typeid_of(Distinct_Integer)] = 7

	distinct_result, distinct_ok := lookup[typeid_of(Distinct_Integer)]
	_, base_ok := lookup[typeid_of(i32)]
	assert(distinct_ok)
	assert(distinct_result == 7)
	assert(!base_ok)
}

probe_binding_type_metadata :: proc() {
	array_info := reflect.type_info_base(type_info_of([2]Distinct_Integer))
	array, array_ok := array_info.variant.(runtime.Type_Info_Array)
	assert(array_ok)
	assert(array.count == 2)
	assert(array.elem.id == typeid_of(Distinct_Integer))

	slice_info := reflect.type_info_base(type_info_of([]Distinct_String))
	slice, slice_ok := slice_info.variant.(runtime.Type_Info_Slice)
	assert(slice_ok)
	assert(slice.elem.id == typeid_of(Distinct_String))

	dynamic_info := reflect.type_info_base(type_info_of([dynamic]Distinct_Integer))
	dynamic_metadata, dynamic_ok := dynamic_info.variant.(runtime.Type_Info_Dynamic_Array)
	assert(dynamic_ok)
	assert(dynamic_metadata.elem.id == typeid_of(Distinct_Integer))

	array_value := [2]Distinct_Integer{11, 12}
	array_iterator := 0
	first_element, first_index, first_ok := reflect.iterate_array(array_value, &array_iterator)
	assert(first_ok)
	assert(first_index == 0)
	assert(first_element.id == typeid_of(Distinct_Integer))
	assert((^Distinct_Integer)(first_element.data)^ == 11)

	map_info := reflect.type_info_base(type_info_of(map[Distinct_String]Distinct_Integer))
	mapping, mapping_ok := map_info.variant.(runtime.Type_Info_Map)
	assert(mapping_ok)
	assert(mapping.key.id == typeid_of(Distinct_String))
	assert(mapping.value.id == typeid_of(Distinct_Integer))

	pointer_info := reflect.type_info_base(type_info_of(^Distinct_Integer))
	pointer, pointer_ok := pointer_info.variant.(runtime.Type_Info_Pointer)
	assert(pointer_ok)
	assert(pointer.elem.id == typeid_of(Distinct_Integer))

	assert(reflect.type_kind(typeid_of(Unsupported_Enum)) == .Named)
	assert(reflect.underlying_type_kind(typeid_of(Unsupported_Enum)) == .Enum)
	assert(reflect.type_kind(typeid_of(Unsupported_Procedure)) == .Named)
	assert(reflect.underlying_type_kind(typeid_of(Unsupported_Procedure)) == .Procedure)
	assert(reflect.type_kind(typeid_of(typeid)) == .Type_Id)
	assert(reflect.type_kind(typeid_of(any)) == .Any)
}

probe_omitempty_inputs :: proc() {
	integer_zero := i64(0)
	empty_dynamic := make([dynamic]i32)
	defer delete(empty_dynamic)
	empty_map := make(map[string]i32)
	defer delete(empty_map)
	nil_pointer: ^i32
	nil_optional: union {i32}

	assert(probe_is_empty(false))
	assert(probe_is_empty(integer_zero))
	assert(probe_is_empty(f64(0.0)))
	assert(probe_is_empty(-f64(0.0)))
	assert(probe_is_empty(""))
	assert(probe_is_empty([0]i32{}))
	assert(probe_is_empty([]i32{}))
	assert(probe_is_empty(empty_dynamic))
	assert(probe_is_empty(empty_map))
	assert(probe_is_empty(nil_pointer))
	assert(probe_is_empty(nil_optional))

	pointer_to_zero := &integer_zero
	assert(!probe_is_empty(pointer_to_zero))
	assert(!probe_is_empty(struct {}{}))

	any_fields := struct {
		nil_value:      any,
		non_nil_value: any,
	}{non_nil_value = integer_zero}
	any_fields_value: any = any_fields
	fields := reflect.struct_fields_zipped(any_fields_value.id)
	assert(probe_is_empty(reflect.struct_field_value(any_fields_value, fields[0])))
	assert(!probe_is_empty(reflect.struct_field_value(any_fields_value, fields[1])))
}

probe_is_empty :: proc(value: any) -> bool {
	if value == nil {
		return true
	}

	info := reflect.type_info_base(type_info_of(value.id))
	#partial switch _ in info.variant {
	case runtime.Type_Info_Boolean:
		core := reflect.any_core(value)
		switch item in core {
		case bool:
			return !item
		case:
			return false
		}
	case runtime.Type_Info_Integer:
		core := reflect.any_core(value)
		signed, signed_ok := reflect.as_i64(core)
		if signed_ok {
			return signed == 0
		}
		unsigned, unsigned_ok := reflect.as_u64(core)
		return unsigned_ok && unsigned == 0
	case runtime.Type_Info_Float:
		core := reflect.any_core(value)
		float, float_ok := reflect.as_f64(core)
		return float_ok && float == 0
	case runtime.Type_Info_String,
	     runtime.Type_Info_Array,
	     runtime.Type_Info_Enumerated_Array,
	     runtime.Type_Info_Slice,
	     runtime.Type_Info_Dynamic_Array,
	     runtime.Type_Info_Map:
		return reflect.length(value) == 0
	case runtime.Type_Info_Pointer:
		return (^rawptr)(value.data)^ == nil
	case runtime.Type_Info_Union:
		return reflect.union_variant_typeid(value) == nil
	case runtime.Type_Info_Any:
		return (^any)(value.data)^ == nil
	}
	return false
}

probe_cycle_identity :: proc() {
	node: Cycle_Node
	node.next = &node

	root: any = node
	next_field := reflect.struct_field_at(Cycle_Node, 0)
	next_destination := reflect.struct_field_value(root, next_field)
	child := reflect.deref(next_destination)
	assert(child.id == typeid_of(Cycle_Node))
	assert(child.data == root.data)

	repeated := struct {
		left, right: ^Cycle_Node,
	}{left = &node, right = &node}
	repeated_any: any = repeated
	repeated_fields := reflect.struct_fields_zipped(repeated_any.id)
	left_field := reflect.struct_field_value(repeated_any, repeated_fields[0])
	right_field := reflect.struct_field_value(repeated_any, repeated_fields[1])
	assert(probe_reference_identity(left_field) == probe_reference_identity(right_field))

	slice, slice_error := make([]i32, 1)
	assert(slice_error == nil)
	defer delete(slice)
	slice_alias := slice
	assert(probe_reference_identity(slice) == probe_reference_identity(slice_alias))

	dynamic_values := make([dynamic]i32, 1)
	defer delete(dynamic_values)
	dynamic_alias := dynamic_values
	assert(probe_reference_identity(dynamic_values) == probe_reference_identity(dynamic_alias))

	mapping, mapping_error := make(map[string]i32, 1)
	assert(mapping_error == nil)
	defer delete(mapping)
	mapping_alias := mapping
	assert(probe_reference_identity(mapping) == probe_reference_identity(mapping_alias))
}

probe_reference_identity :: proc(value: any) -> rawptr {
	info := reflect.type_info_base(type_info_of(value.id))
	#partial switch _ in info.variant {
	case runtime.Type_Info_Pointer:
		return (^rawptr)(value.data)^
	case runtime.Type_Info_Slice:
		return (^mem.Raw_Slice)(value.data).data
	case runtime.Type_Info_Dynamic_Array:
		return (^mem.Raw_Dynamic_Array)(value.data).data
	case runtime.Type_Info_Map:
		raw_map := (^mem.Raw_Map)(value.data)
		return rawptr(runtime.map_data(raw_map^))
	}
	return nil
}

probe_optional_union_and_wrapper_destinations :: proc() {
	union_info := reflect.type_info_base(type_info_of(Optional_Wrapper))
	union_metadata, union_ok := union_info.variant.(runtime.Type_Info_Union)
	assert(union_ok)
	assert(!union_metadata.no_nil)
	assert(len(union_metadata.variants) == 1)
	assert(union_metadata.variants[0].id == typeid_of(Wrapper_Value))

	destination: Wrapper_Destination
	fields := reflect.struct_fields_zipped(Wrapper_Destination)
	pointer_destination := reflect.struct_field_value(destination, fields[0])
	optional_destination := reflect.struct_field_value(destination, fields[1])

	pointee := Wrapper_Value{}
	switch &pointer in pointer_destination {
	case ^Wrapper_Value:
		pointer = &pointee
	case:
		assert(false)
	}
	pointer_value := reflect.deref(pointer_destination)
	assert(pointer_value.id == typeid_of(Wrapper_Value))
	value_field := reflect.struct_field_at(Wrapper_Value, 0)
	wrapped_value := reflect.struct_field_value(pointer_value, value_field)
	switch &value in wrapped_value {
	case i32:
		value = 51
	case:
		assert(false)
	}
	assert(destination.pointer == &pointee)
	assert(destination.pointer.value == 51)

	assert(reflect.union_variant_typeid(optional_destination) == nil)
	activated := reflect.set_union_value(optional_destination, Wrapper_Value{})
	assert(activated)
	assert(reflect.union_variant_typeid(optional_destination) == typeid_of(Wrapper_Value))
	optional_value := reflect.get_union_variant(optional_destination)
	optional_field := reflect.struct_field_value(optional_value, value_field)
	switch &value in optional_field {
	case i32:
		value = 52
	case:
		assert(false)
	}
	assert(destination.optional.(Wrapper_Value).value == 52)
}

probe_allocator_controlled_container_installation :: proc() {
	events: [64]support.Allocator_Event
	live: [16]support.Live_Allocation
	state: support.Observed_Allocator
	support.observed_allocator_init(&state, context.allocator, events[:], live[:])
	allocator := support.observed_allocator(&state)

	rejecting_state: support.Rejecting_Allocator
	rejecting := support.rejecting_allocator(&rejecting_state)
	previous_allocator := context.allocator
	context.allocator = rejecting
	defer context.allocator = previous_allocator

	destination: Container_Destination
	fields := reflect.struct_fields_zipped(Container_Destination)
	mapping_destination := reflect.struct_field_value(destination, fields[0])
	values_destination := reflect.struct_field_value(destination, fields[1])
	items_destination := reflect.struct_field_value(destination, fields[2])

	mapping_info := reflect.type_info_base(type_info_of(mapping_destination.id))
	mapping, mapping_ok := mapping_info.variant.(runtime.Type_Info_Map)
	assert(mapping_ok)
	raw_mapping := (^mem.Raw_Map)(mapping_destination.data)
	raw_mapping.allocator = allocator
	key := "key"
	value := i32(61)
	_, map_error := runtime.__dynamic_map_set_without_hash(
		raw_mapping,
		mapping.map_info,
		&key,
		&value,
	)
	assert(map_error == nil)
	assert(destination.mapping.allocator.procedure == allocator.procedure)
	assert(destination.mapping.allocator.data == allocator.data)
	assert(destination.mapping["key"] == 61)
	map_iterator := 0
	map_key, map_value, map_ok := reflect.iterate_map(mapping_destination, &map_iterator)
	assert(map_ok)
	assert(map_key.id == typeid_of(string))
	assert(map_value.id == typeid_of(i32))
	assert((^string)(map_key.data)^ == "key")
	assert((^i32)(map_value.data)^ == 61)

	values_info := reflect.type_info_base(type_info_of(values_destination.id))
	values, values_ok := values_info.variant.(runtime.Type_Info_Slice)
	assert(values_ok)
	values_storage, values_storage_error := mem.alloc_bytes(
		values.elem.size*2,
		values.elem.align,
		allocator,
	)
	assert(values_storage_error == nil)
	raw_values := (^mem.Raw_Slice)(values_destination.data)
	raw_values.data = raw_data(values_storage)
	raw_values.len = 2
	value_items := ([^]i32)(raw_values.data)
	value_items[0] = 64
	value_items[1] = 65
	assert(len(destination.values) == 2)
	assert(destination.values[0] == 64)
	assert(destination.values[1] == 65)

	items_info := reflect.type_info_base(type_info_of(items_destination.id))
	items, items_ok := items_info.variant.(runtime.Type_Info_Dynamic_Array)
	assert(items_ok)
	storage, storage_error := mem.alloc_bytes(
		items.elem.size*2,
		items.elem.align,
		allocator,
	)
	assert(storage_error == nil)
	raw_items := (^mem.Raw_Dynamic_Array)(items_destination.data)
	raw_items.data = raw_data(storage)
	raw_items.len = 2
	raw_items.cap = 2
	raw_items.allocator = allocator
	item_values := ([^]i32)(raw_items.data)
	item_values[0] = 62
	item_values[1] = 63
	assert(destination.items.allocator.procedure == allocator.procedure)
	assert(destination.items.allocator.data == allocator.data)
	assert(len(destination.items) == 2)
	assert(destination.items[0] == 62)
	assert(destination.items[1] == 63)

	assert(state.allocation_request_count >= 3)
	assert(rejecting_state.allocation_attempt_count == 0)
	assert(delete(destination.mapping) == nil)
	assert(delete(destination.values, allocator) == nil)
	assert(delete(destination.items) == nil)
	assert(state.live_count == 0)
	assert(state.foreign_release_count == 0)
}

probe_aligned_zero_size_pointee_installation :: proc() {
	assert(size_of(Aligned_Empty) == 0)
	assert(align_of(Aligned_Empty) == 64)

	events: [16]support.Allocator_Event
	live: [4]support.Live_Allocation
	state: support.Observed_Allocator
	support.observed_allocator_init(&state, context.allocator, events[:], live[:])
	allocator := support.observed_allocator(&state)

	storage, storage_error := mem.alloc_bytes(1, align_of(Aligned_Empty), allocator)
	assert(storage_error == nil)
	pointee := (^Aligned_Empty)(raw_data(storage))
	assert(pointee != nil)
	assert(uintptr(pointee)%uintptr(align_of(Aligned_Empty)) == 0)
	destination := struct {pointer: ^Aligned_Empty}{}
	destination_any: any = destination
	pointer_field := reflect.struct_field_at(destination_any.id, 0)
	pointer_destination := reflect.struct_field_value(destination_any, pointer_field)
	(^rawptr)(pointer_destination.data)^ = raw_data(storage)
	assert(destination.pointer == pointee)
	assert(state.event_count >= 1)
	assert(state.events[0].size == 1)
	assert(state.events[0].alignment == align_of(Aligned_Empty))
	assert(mem.free_bytes(storage, allocator) == nil)
	assert(state.live_count == 0)
}

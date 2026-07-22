package toml

import "base:runtime"
import "core:reflect"
import temporal "temporal"

@(private)
Unmarshal_State :: struct {
	allocator: runtime.Allocator,
	loc:       runtime.Source_Code_Location,
	max_depth: int,
	reject_unknown_fields: bool,
	parser:    Parser_State,
	ranges:    Binding_Range_Node_Array,
	builder:   Marshal_Builder,
	path:      [SEMANTIC_MAX_DEPTH + 1]Encode_Diagnostic_Path_Segment,
	path_count: int,
	type_stack: [SEMANTIC_MAX_DEPTH + 1]typeid,
	type_count: int,
}

@(private)
unmarshal_configuration :: proc(
	destination: rawptr,
	options: Unmarshal_Options,
	allocator: runtime.Allocator,
) -> (int, Unmarshal_Error) {
	if allocator.procedure == nil {
		return 0, Unmarshal_Configuration_Error.Invalid_Allocator
	}
	max_depth := options.max_depth
	if max_depth == 0 {
		max_depth = 128
	} else if max_depth < 1 || max_depth > SEMANTIC_MAX_DEPTH {
		return 0, Unmarshal_Configuration_Error.Invalid_Max_Depth
	}
	if destination == nil {
		return 0, Unmarshal_Configuration_Error.Nil_Destination
	}
	if options.codecs != nil && !codec_registry_is_valid(options.codecs) {
		return 0, Unmarshal_Configuration_Error.Invalid_Codec_Registry
	}
	return max_depth, nil
}

@(private)
unmarshal_path_snapshot :: proc(state: ^Unmarshal_State) -> Encode_Diagnostic_Path {
	result: Encode_Diagnostic_Path
	count := state.path_count
	result.total_segment_count = u16(count)
	if count <= len(result.segments) {
		result.segment_count = u8(count)
		result.prefix_count = u8(count)
		copy(result.segments[:count], state.path[:count])
		return result
	}
	prefix_count := 8
	suffix_count := len(result.segments)-prefix_count
	result.segment_count = u8(len(result.segments))
	result.prefix_count = u8(prefix_count)
	result.omitted_segment_count = u16(count-len(result.segments))
	result.truncated = true
	copy(result.segments[:prefix_count], state.path[:prefix_count])
	copy(result.segments[prefix_count:], state.path[count-suffix_count:count])
	return result
}

@(private)
unmarshal_diagnostic_detail :: proc(
	state: ^Unmarshal_State,
	kind: Unmarshal_Data_Error_Kind,
	destination_type: typeid,
	source_kind: Value_Kind,
	source: Optional_Source_Range,
	related_type: typeid,
	expected_count, actual_count: int,
) -> Unmarshal_Error {
	return Unmarshal_Diagnostic{
		detail = Unmarshal_Data_Error{
			kind = kind,
			destination_type = destination_type,
			source_kind = source_kind,
			related_type = related_type,
			expected_count = expected_count,
			actual_count = actual_count,
		},
		source = source,
		path = unmarshal_path_snapshot(state),
	}
}

@(private)
unmarshal_diagnostic :: proc(
	state: ^Unmarshal_State,
	kind: Unmarshal_Data_Error_Kind,
	destination_type: typeid,
	source_kind: Value_Kind,
	source: Optional_Source_Range = {},
	expected_count := 0,
	actual_count := 0,
) -> Unmarshal_Error {
	return unmarshal_diagnostic_detail(
		state,
		kind,
		destination_type,
		source_kind,
		source,
		nil,
		expected_count,
		actual_count,
	)
}

@(private)
unmarshal_source :: proc(source: Source_Range) -> Optional_Source_Range {
	return {value = source, ok = true}
}

@(private)
unmarshal_push_path :: proc(
	state: ^Unmarshal_State,
	segment: Encode_Diagnostic_Path_Segment,
	source: Source_Range,
	destination_type: typeid,
	source_kind: Value_Kind,
) -> Unmarshal_Error {
	state.path[state.path_count] = segment
	state.path_count += 1
	if state.path_count > state.max_depth {
		err := unmarshal_diagnostic(
			state,
			.Maximum_Depth_Exceeded,
			destination_type,
			source_kind,
			unmarshal_source(source),
		)
		state.path_count -= 1
		state.path[state.path_count] = {}
		return err
	}
	return nil
}

@(private)
unmarshal_pop_path :: proc(state: ^Unmarshal_State) {
	assert(state.path_count > 0)
	state.path_count -= 1
	state.path[state.path_count] = {}
}

@(private)
unmarshal_value_kind :: proc(value: Value) -> Value_Kind {
	switch _ in value {
	case String: return .String
	case Integer: return .Integer
	case Float: return .Float
	case Boolean: return .Boolean
	case temporal.Offset_Date_Time: return .Offset_Date_Time
	case temporal.Local_Date_Time: return .Local_Date_Time
	case temporal.Local_Date: return .Local_Date
	case temporal.Local_Time: return .Local_Time
	case Array: return .Array
	case Table: return .Table
	}
	unreachable()
}

@(private)
unmarshal_plan_error :: proc(
	state: ^Unmarshal_State,
	err: Marshal_Error,
	destination_type: typeid,
	source: Optional_Source_Range,
) -> Unmarshal_Error {
	if err == nil {
		return nil
	}
	if allocator_error, ok := err.(runtime.Allocator_Error); ok {
		return allocator_error
	}
	diagnostic := err.(Marshal_Diagnostic)
	if limit, ok := diagnostic.detail.(Marshal_Limit_Error); ok {
		kind := Unmarshal_Data_Error_Kind.Destination_Size_Overflow
		if limit == .Maximum_Depth_Exceeded {
			kind = .Maximum_Depth_Exceeded
		}
		return unmarshal_diagnostic(state, kind, destination_type, {}, source)
	}
	data := diagnostic.detail.(Marshal_Data_Error)
	kind := Unmarshal_Data_Error_Kind.Unsupported_Destination_Type
	#partial switch data.kind {
	case .Malformed_Tag:
		kind = .Malformed_Tag
	case .Effective_Field_Name_Collision:
		kind = .Effective_Field_Name_Collision
	}
	relevant_type := destination_type
	if data.source_type != nil {
		relevant_type = data.source_type
	}
	return unmarshal_diagnostic_detail(
		state,
		kind,
		relevant_type,
		{},
		source,
		data.related_type,
		0,
		0,
	)
}

@(private)
unmarshal_struct_plan :: proc(
	state: ^Unmarshal_State,
	destination_type: typeid,
	source: Optional_Source_Range,
) -> (Marshal_Struct_Plan, Unmarshal_Error) {
	plan, err := marshal_struct_plan_build(&state.builder, destination_type)
	if err != nil {
		return {}, unmarshal_plan_error(state, err, destination_type, source)
	}
	return plan, nil
}

@(private)
unmarshal_type_enter :: proc(state: ^Unmarshal_State, id: typeid) -> bool {
	for active in state.type_stack[:state.type_count] {
		if active == id {
			return false
		}
	}
	if state.type_count >= len(state.type_stack) {
		return false
	}
	state.type_stack[state.type_count] = id
	state.type_count += 1
	return true
}

@(private)
unmarshal_type_leave :: proc(state: ^Unmarshal_State, entered: bool) {
	if !entered {
		return
	}
	assert(state.type_count > 0)
	state.type_count -= 1
	state.type_stack[state.type_count] = nil
}

@(private)
unmarshal_validate_declared_type :: proc(
	state: ^Unmarshal_State,
	destination_type: typeid,
	source: Optional_Source_Range,
) -> Unmarshal_Error {
	if marshal_is_temporal_type(destination_type) {
		return nil
	}
	if destination_type == typeid_of(any) || marshal_is_semantic_binding_type(destination_type) {
		return unmarshal_diagnostic(
			state, .Unsupported_Destination_Type, destination_type, {}, source,
		)
	}
	info := reflect.type_info_base(type_info_of(destination_type))
	#partial switch metadata in info.variant {
	case runtime.Type_Info_String:
		if metadata.is_cstring || metadata.encoding != .UTF_8 {
			return unmarshal_diagnostic(
				state, .Unsupported_Destination_Type, destination_type, {}, source,
			)
		}
		return nil
	case runtime.Type_Info_Boolean:
		return nil
	case runtime.Type_Info_Integer:
		if info.size <= 0 || info.size > size_of(i128) {
			return unmarshal_diagnostic(
				state, .Unsupported_Destination_Type, destination_type, {}, source,
			)
		}
		return nil
	case runtime.Type_Info_Float:
		if info.size != size_of(f16) && info.size != size_of(f32) && info.size != size_of(f64) {
			return unmarshal_diagnostic(
				state, .Unsupported_Destination_Type, destination_type, {}, source,
			)
		}
		return nil
	case runtime.Type_Info_Struct:
		if .raw_union in metadata.flags {
			return unmarshal_diagnostic(
				state, .Unsupported_Destination_Type, destination_type, {}, source,
			)
		}
		entered := unmarshal_type_enter(state, destination_type)
		if !entered {
			return nil
		}
		defer unmarshal_type_leave(state, entered)
		plan, plan_error := unmarshal_struct_plan(state, destination_type, source)
		if plan_error != nil {
			return plan_error
		}
		defer marshal_struct_plan_destroy(&state.builder, &plan)
		for field in plan.fields {
			if err := unmarshal_validate_declared_type(
				state, field.source_type, source,
			); err != nil {
				return err
			}
		}
		return nil
	case runtime.Type_Info_Array:
		if metadata.count < 0 || metadata.elem_size < 0 ||
		   metadata.count > 0 && metadata.elem_size > max(int)/metadata.count {
			return unmarshal_diagnostic(
				state, .Destination_Size_Overflow, destination_type, {}, source,
			)
		}
		entered := unmarshal_type_enter(state, destination_type)
		defer unmarshal_type_leave(state, entered)
		if entered {
			return unmarshal_validate_declared_type(state, metadata.elem.id, source)
		}
		return nil
	case runtime.Type_Info_Enumerated_Array:
		if metadata.count < 0 || metadata.elem_size < 0 ||
		   metadata.count > 0 && metadata.elem_size > max(int)/metadata.count {
			return unmarshal_diagnostic(
				state, .Destination_Size_Overflow, destination_type, {}, source,
			)
		}
		entered := unmarshal_type_enter(state, destination_type)
		defer unmarshal_type_leave(state, entered)
		if entered {
			return unmarshal_validate_declared_type(state, metadata.elem.id, source)
		}
		return nil
	case runtime.Type_Info_Slice:
		entered := unmarshal_type_enter(state, destination_type)
		defer unmarshal_type_leave(state, entered)
		if entered {
			return unmarshal_validate_declared_type(state, metadata.elem.id, source)
		}
		return nil
	case runtime.Type_Info_Dynamic_Array:
		entered := unmarshal_type_enter(state, destination_type)
		defer unmarshal_type_leave(state, entered)
		if entered {
			return unmarshal_validate_declared_type(state, metadata.elem.id, source)
		}
		return nil
	case runtime.Type_Info_Map:
		key_info := reflect.type_info_base(type_info_of(metadata.key.id))
		key_metadata, key_ok := key_info.variant.(runtime.Type_Info_String)
		if !key_ok || key_metadata.is_cstring || key_metadata.encoding != .UTF_8 {
			return unmarshal_diagnostic(
				state, .Unsupported_Destination_Type, destination_type, {}, source,
			)
		}
		entered := unmarshal_type_enter(state, destination_type)
		defer unmarshal_type_leave(state, entered)
		if entered {
			return unmarshal_validate_declared_type(state, metadata.value.id, source)
		}
		return nil
	case runtime.Type_Info_Pointer:
		if metadata.elem == nil {
			return unmarshal_diagnostic(
				state, .Unsupported_Destination_Type, destination_type, {}, source,
			)
		}
		entered := unmarshal_type_enter(state, destination_type)
		defer unmarshal_type_leave(state, entered)
		if entered {
			return unmarshal_validate_declared_type(state, metadata.elem.id, source)
		}
		return nil
	case runtime.Type_Info_Union:
		if metadata.no_nil || len(metadata.variants) != 1 {
			return unmarshal_diagnostic(
				state, .Unsupported_Destination_Type, destination_type, {}, source,
			)
		}
		entered := unmarshal_type_enter(state, destination_type)
		defer unmarshal_type_leave(state, entered)
		if entered {
			return unmarshal_validate_declared_type(state, metadata.variants[0].id, source)
		}
		return nil
	}
	return unmarshal_diagnostic(
		state, .Unsupported_Destination_Type, destination_type, {}, source,
	)
}

@(private)
unmarshal_integer_fits :: proc(value: Integer, destination_type: typeid) -> bool {
	info := reflect.type_info_base(type_info_of(destination_type))
	metadata, ok := info.variant.(runtime.Type_Info_Integer)
	if !ok || info.size <= 0 || info.size > size_of(i128) {
		return false
	}
	bits := info.size*8
	if metadata.signed {
		if bits >= 64 {
			return true
		}
		limit: i64 = i64(1) << u64(bits-1)
		return -limit <= i64(value) && i64(value) < limit
	}
	if value < 0 {
		return false
	}
	if bits >= 64 {
		return true
	}
	return u64(value) < u64(1)<<u64(bits)
}

@(private)
unmarshal_float_fits :: proc(value: Float, destination_type: typeid) -> bool {
	info := reflect.type_info_base(type_info_of(destination_type))
	if _, ok := info.variant.(runtime.Type_Info_Float); !ok {
		return false
	}
	bits := transmute(u64)f64(value)
	finite := bits&0x7ff0_0000_0000_0000 != 0x7ff0_0000_0000_0000
	if !finite || info.size == size_of(f64) {
		return info.size == size_of(f16) || info.size == size_of(f32) || info.size == size_of(f64)
	}
	if info.size == size_of(f32) {
		converted := f32(value)
		return transmute(u32)converted&0x7f80_0000 != 0x7f80_0000
	}
	if info.size == size_of(f16) {
		converted := f16(value)
		return transmute(u16)converted&0x7c00 != 0x7c00
	}
	return false
}

@(private)
unmarshal_source_for_entry :: proc(
	state: ^Unmarshal_State,
	parent_node, parent_range, entry_index: int,
	fallback: Source_Range,
) -> (
	node_id, binding_range_id: int,
	key_source, value_source: Source_Range,
) {
	if parent_node >= 0 {
		node_id = parser_node_for_entry(&state.parser, parent_node, entry_index)
		if node_id == 0 {
			node_id = parser_node_for_array_element(&state.parser, parent_node, entry_index)
		}
		if node_id != 0 {
			node := state.parser.nodes[node_id-1]
			return node_id, node.binding_range_id, node.key_range, node.value_range
		}
	}
	if parent_range > 0 {
		for range, index in state.ranges {
			if range.parent == parent_range && range.semantic_index == entry_index {
				return -1, index+1, range.key_source, range.source
			}
		}
	}
	return -1, 0, fallback, fallback
}

@(private)
unmarshal_child_parent_node :: proc(
	state: ^Unmarshal_State,
	node_id: int,
) -> int {
	if node_id <= 0 {
		return -1
	}
	node := state.parser.nodes[node_id-1]
	if node.form == .Inline_Table {
		return -1
	}
	return node_id
}

@(private)
unmarshal_slot_is_exact_zero :: proc(destination: any) -> bool {
	info := reflect.type_info_base(type_info_of(destination.id))
	bytes := ([^]byte)(destination.data)[:info.size]
	for byte in bytes {
		if byte != 0 {
			return false
		}
	}
	return true
}

@(private)
unmarshal_string_slot_is_zero :: proc(destination: any) -> bool {
	raw := (^runtime.Raw_String)(destination.data)^
	return raw.data == nil && raw.len == 0
}

@(private)
unmarshal_preflight_value :: proc(
	state: ^Unmarshal_State,
	source: Value,
	destination: any,
	node_id, binding_range_id: int,
	source_range: Source_Range,
) -> Unmarshal_Error {
	kind := unmarshal_value_kind(source)
	optional_source := unmarshal_source(source_range)
	if destination.id == typeid_of(temporal.Offset_Date_Time) {
		if _, ok := source.(temporal.Offset_Date_Time); !ok {
			return unmarshal_diagnostic(
				state, .Source_Destination_Kind_Mismatch, destination.id, kind, optional_source,
			)
		}
		return nil
	}
	if destination.id == typeid_of(temporal.Local_Date_Time) {
		if _, ok := source.(temporal.Local_Date_Time); !ok {
			return unmarshal_diagnostic(
				state, .Source_Destination_Kind_Mismatch, destination.id, kind, optional_source,
			)
		}
		return nil
	}
	if destination.id == typeid_of(temporal.Local_Date) {
		if _, ok := source.(temporal.Local_Date); !ok {
			return unmarshal_diagnostic(
				state, .Source_Destination_Kind_Mismatch, destination.id, kind, optional_source,
			)
		}
		return nil
	}
	if destination.id == typeid_of(temporal.Local_Time) {
		if _, ok := source.(temporal.Local_Time); !ok {
			return unmarshal_diagnostic(
				state, .Source_Destination_Kind_Mismatch, destination.id, kind, optional_source,
			)
		}
		return nil
	}
	info := reflect.type_info_base(type_info_of(destination.id))
	#partial switch _ in info.variant {
	case runtime.Type_Info_String:
		if _, ok := source.(String); !ok {
			return unmarshal_diagnostic(
				state, .Source_Destination_Kind_Mismatch, destination.id, kind, optional_source,
			)
		}
		if !unmarshal_string_slot_is_zero(destination) {
			return unmarshal_diagnostic(
				state, .Nonzero_Destination_Ownership, destination.id, kind, optional_source,
			)
		}
		return unmarshal_diagnostic(
			state, .Unsupported_Destination_Type, destination.id, kind, optional_source,
		)
	case runtime.Type_Info_Boolean:
		if _, ok := source.(Boolean); !ok {
			return unmarshal_diagnostic(
				state, .Source_Destination_Kind_Mismatch, destination.id, kind, optional_source,
			)
		}
		return nil
	case runtime.Type_Info_Integer:
		value, ok := source.(Integer)
		if !ok {
			return unmarshal_diagnostic(
				state, .Source_Destination_Kind_Mismatch, destination.id, kind, optional_source,
			)
		}
		if !unmarshal_integer_fits(value, destination.id) {
			return unmarshal_diagnostic(
				state, .Integer_Out_Of_Range, destination.id, kind, optional_source,
			)
		}
		return nil
	case runtime.Type_Info_Float:
		value, ok := source.(Float)
		if !ok {
			return unmarshal_diagnostic(
				state, .Source_Destination_Kind_Mismatch, destination.id, kind, optional_source,
			)
		}
		if !unmarshal_float_fits(value, destination.id) {
			return unmarshal_diagnostic(
				state, .Float_Out_Of_Range, destination.id, kind, optional_source,
			)
		}
		return nil
	case runtime.Type_Info_Struct:
		table, ok := source.(Table)
		if !ok {
			return unmarshal_diagnostic(
				state, .Source_Destination_Kind_Mismatch, destination.id, kind, optional_source,
			)
		}
		return unmarshal_preflight_struct(
			state,
			table,
			destination,
			unmarshal_child_parent_node(state, node_id),
			binding_range_id,
			source_range,
		)
	case runtime.Type_Info_Array:
		array, ok := source.(Array)
		if !ok {
			return unmarshal_diagnostic(
				state, .Source_Destination_Kind_Mismatch, destination.id, kind, optional_source,
			)
		}
		metadata := info.variant.(runtime.Type_Info_Array)
		if len(array) != metadata.count {
			return unmarshal_diagnostic(
				state,
				.Fixed_Array_Length_Mismatch,
				destination.id,
				kind,
				optional_source,
				metadata.count,
				len(array),
			)
		}
		if err := unmarshal_preflight_fixed_array(
			state,
			array,
			destination,
			metadata.elem.id,
			metadata.elem_size,
			node_id,
			binding_range_id,
			source_range,
		); err != nil {
			return err
		}
	case runtime.Type_Info_Enumerated_Array:
		array, ok := source.(Array)
		if !ok {
			return unmarshal_diagnostic(
				state, .Source_Destination_Kind_Mismatch, destination.id, kind, optional_source,
			)
		}
		metadata := info.variant.(runtime.Type_Info_Enumerated_Array)
		if len(array) != metadata.count {
			return unmarshal_diagnostic(
				state,
				.Fixed_Array_Length_Mismatch,
				destination.id,
				kind,
				optional_source,
				metadata.count,
				len(array),
			)
		}
		if err := unmarshal_preflight_fixed_array(
			state,
			array,
			destination,
			metadata.elem.id,
			metadata.elem_size,
			node_id,
			binding_range_id,
			source_range,
		); err != nil {
			return err
		}
	case runtime.Type_Info_Slice, runtime.Type_Info_Dynamic_Array:
		if _, ok := source.(Array); !ok {
			return unmarshal_diagnostic(
				state, .Source_Destination_Kind_Mismatch, destination.id, kind, optional_source,
			)
		}
		if !unmarshal_slot_is_exact_zero(destination) {
			return unmarshal_diagnostic(
				state, .Nonzero_Destination_Ownership, destination.id, kind, optional_source,
			)
		}
	case runtime.Type_Info_Map:
		if _, ok := source.(Table); !ok {
			return unmarshal_diagnostic(
				state, .Source_Destination_Kind_Mismatch, destination.id, kind, optional_source,
			)
		}
		if !unmarshal_slot_is_exact_zero(destination) {
			return unmarshal_diagnostic(
				state, .Nonzero_Destination_Ownership, destination.id, kind, optional_source,
			)
		}
	case runtime.Type_Info_Pointer, runtime.Type_Info_Union:
		if !unmarshal_slot_is_exact_zero(destination) {
			return unmarshal_diagnostic(
				state, .Nonzero_Destination_Ownership, destination.id, kind, optional_source,
			)
		}
	}
	return unmarshal_diagnostic(
		state, .Unsupported_Destination_Type, destination.id, kind, optional_source,
	)
}

@(private)
unmarshal_preflight_fixed_array :: proc(
	state: ^Unmarshal_State,
	source: Array,
	destination: any,
	element_type: typeid,
	element_size: int,
	parent_node, binding_range_id: int,
	fallback_source: Source_Range,
) -> Unmarshal_Error {
	for child, index in source {
		child_node_id, child_range_id, _, child_source := unmarshal_source_for_entry(
			state, parent_node, binding_range_id, index, fallback_source,
		)
		if path_error := unmarshal_push_path(
			state,
			Path_Index(index),
			child_source,
			element_type,
			unmarshal_value_kind(child),
		); path_error != nil {
			return path_error
		}
		element_data := rawptr(uintptr(destination.data)+uintptr(index*element_size))
		if element_size == 0 && element_data == nil {
			element_data = rawptr(state)
		}
		element := any{element_data, element_type}
		err := unmarshal_preflight_value(
			state, child, element, child_node_id, child_range_id, child_source,
		)
		unmarshal_pop_path(state)
		if err != nil {
			return err
		}
	}
	return nil
}

@(private)
unmarshal_preflight_struct :: proc(
	state: ^Unmarshal_State,
	source: Table,
	destination: any,
	parent_node, parent_range: int,
	fallback_source: Source_Range,
) -> Unmarshal_Error {
	optional_source := unmarshal_source(fallback_source)
	if parent_node == 0 && parent_range == 0 && fallback_source == (Source_Range{}) {
		optional_source = {}
	}
	plan, plan_error := unmarshal_struct_plan(state, destination.id, optional_source)
	if plan_error != nil {
		return plan_error
	}
	defer marshal_struct_plan_destroy(&state.builder, &plan)
	for field in plan.fields {
		if err := unmarshal_validate_declared_type(
			state, field.source_type, optional_source,
		); err != nil {
			return err
		}
	}
	for entry, entry_index in source {
		matched_index := -1
		for projected, projected_index in plan.fields {
			if projected.tag.name == entry.key {
				matched_index = projected_index
				break
			}
		}
		node_id, binding_range_id, key_source, value_source := unmarshal_source_for_entry(
			state, parent_node, parent_range, entry_index, fallback_source,
		)
		if matched_index < 0 {
			if state.reject_unknown_fields {
				// The decoded key is owned by the temporary document and is destroyed
				// before return. Keep the stable parent path and numeric source range
				// rather than returning a dangling path-string borrow.
				return unmarshal_diagnostic(
					state,
					.Unknown_Field,
					destination.id,
					unmarshal_value_kind(entry.value),
					unmarshal_source(key_source),
				)
			}
			continue
		}
		projected := plan.fields[matched_index]
		if path_error := unmarshal_push_path(
			state,
			projected.tag.name,
			value_source,
			projected.source_type,
			unmarshal_value_kind(entry.value),
		); path_error != nil {
			return path_error
		}
		field := any{
			rawptr(uintptr(destination.data)+projected.offset),
			projected.source_type,
		}
		err := unmarshal_preflight_value(
			state,
			entry.value,
			field,
			node_id,
			binding_range_id,
			value_source,
		)
		unmarshal_pop_path(state)
		if err != nil {
			return err
		}
	}
	return nil
}

@(private)
unmarshal_assign_integer :: proc(destination: any, source: Integer) {
	core := reflect.any_core(destination)
	switch &value in core {
	case int: value = int(source)
	case i8: value = i8(source)
	case i16: value = i16(source)
	case i32: value = i32(source)
	case i64: value = i64(source)
	case i128: value = i128(source)
	case i16le: value = i16le(source)
	case i32le: value = i32le(source)
	case i64le: value = i64le(source)
	case i128le: value = i128le(source)
	case i16be: value = i16be(source)
	case i32be: value = i32be(source)
	case i64be: value = i64be(source)
	case i128be: value = i128be(source)
	case uint: value = uint(source)
	case uintptr: value = uintptr(source)
	case u8: value = u8(source)
	case u16: value = u16(source)
	case u32: value = u32(source)
	case u64: value = u64(source)
	case u128: value = u128(source)
	case u16le: value = u16le(source)
	case u32le: value = u32le(source)
	case u64le: value = u64le(source)
	case u128le: value = u128le(source)
	case u16be: value = u16be(source)
	case u32be: value = u32be(source)
	case u64be: value = u64be(source)
	case u128be: value = u128be(source)
	case: unreachable()
	}
}

@(private)
unmarshal_assign_float :: proc(destination: any, source: Float) {
	core := reflect.any_core(destination)
	switch &value in core {
	case f16: value = f16(source)
	case f32: value = f32(source)
	case f64: value = f64(source)
	case f32le: value = f32le(source)
	case f64le: value = f64le(source)
	case f32be: value = f32be(source)
	case f64be: value = f64be(source)
	case: unreachable()
	}
}

@(private)
unmarshal_assign_value :: proc(source: Value, destination: any) {
	if destination.id == typeid_of(temporal.Offset_Date_Time) {
		(^temporal.Offset_Date_Time)(destination.data)^ = source.(temporal.Offset_Date_Time)
		return
	}
	if destination.id == typeid_of(temporal.Local_Date_Time) {
		(^temporal.Local_Date_Time)(destination.data)^ = source.(temporal.Local_Date_Time)
		return
	}
	if destination.id == typeid_of(temporal.Local_Date) {
		(^temporal.Local_Date)(destination.data)^ = source.(temporal.Local_Date)
		return
	}
	if destination.id == typeid_of(temporal.Local_Time) {
		(^temporal.Local_Time)(destination.data)^ = source.(temporal.Local_Time)
		return
	}
	info := reflect.type_info_base(type_info_of(destination.id))
	#partial switch _ in info.variant {
	case runtime.Type_Info_Boolean:
		core := reflect.any_core(destination)
		switch &value in core {
		case bool: value = bool(source.(Boolean))
		case: unreachable()
		}
	case runtime.Type_Info_Integer:
		unmarshal_assign_integer(destination, source.(Integer))
	case runtime.Type_Info_Float:
		unmarshal_assign_float(destination, source.(Float))
	case runtime.Type_Info_Struct:
		unmarshal_assign_struct(source.(Table), destination)
	case:
		unreachable()
	}
}

@(private)
unmarshal_assign_struct :: proc(source: Table, destination: any) {
	parser := Marshal_Builder{max_depth = SEMANTIC_MAX_DEPTH}
	for entry in source {
		_, field, matched := marshal_projected_field_value_by_name(
			&parser, destination, entry.key,
		)
		if !matched {
			continue
		}
		unmarshal_assign_value(entry.value, field)
	}
}

@(private)
unmarshal_document :: proc(
	input: string,
	destination: rawptr,
	destination_type: typeid,
	options: Unmarshal_Options,
	allocator: runtime.Allocator,
	loc: runtime.Source_Code_Location,
) -> Unmarshal_Error {
	max_depth, configuration_error := unmarshal_configuration(destination, options, allocator)
	if configuration_error != nil {
		return configuration_error
	}
	document, nodes, ranges, parse_error := parse_ranged_document(
		input, {max_depth = max_depth}, allocator, loc,
	)
	if parse_error != nil {
		return Unmarshal_Parse_Error{error = parse_error}
	}
	defer destroy_document(&document, loc)
	defer destroy_ranged_parse_state(&nodes, &ranges, allocator, loc)

	state := Unmarshal_State{
		allocator = allocator,
		loc = loc,
		max_depth = max_depth,
		reject_unknown_fields = options.reject_unknown_fields,
	}
	state.parser.root = document.root
	state.parser.nodes = nodes
	state.ranges = ranges
	state.builder.allocator = allocator
	state.builder.loc = loc
	state.builder.max_depth = max_depth
	gate_error: runtime.Allocator_Error
	state.builder.gate, gate_error = allocator_release_gate_init(allocator, loc)
	if gate_error != nil {
		return gate_error
	}

	destination_value := any{destination, destination_type}
	info := reflect.type_info_base(type_info_of(destination_type))
	metadata, root_ok := info.variant.(runtime.Type_Info_Struct)
	if !root_ok || .raw_union in metadata.flags {
		return unmarshal_diagnostic(
			&state, .Invalid_Root_Shape, destination_type, .Table,
		)
	}
	if preflight_error := unmarshal_preflight_struct(
		&state, document.root, destination_value, 0, 0, {},
	); preflight_error != nil {
		return preflight_error
	}
	unmarshal_assign_struct(document.root, destination_value)
	return nil
}

@(require_results)
unmarshal :: proc(
	input: []byte,
	destination: ^$T,
	options: Unmarshal_Options = {},
	allocator := context.allocator,
	loc := #caller_location,
) -> Unmarshal_Error {
	return unmarshal_document(
		string(input), rawptr(destination), typeid_of(T), options, allocator, loc,
	)
}

@(require_results)
unmarshal_string :: proc(
	input: string,
	destination: ^$T,
	options: Unmarshal_Options = {},
	allocator := context.allocator,
	loc := #caller_location,
) -> Unmarshal_Error {
	return unmarshal_document(
		input, rawptr(destination), typeid_of(T), options, allocator, loc,
	)
}

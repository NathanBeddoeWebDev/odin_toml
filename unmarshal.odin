package toml

import "base:runtime"
import "core:reflect"
import temporal "temporal"

@(private)
Unmarshal_Source :: struct {
	value: Source_Byte_Range,
	ok:    bool,
}

@(private)
Unmarshal_State :: struct {
	allocator: runtime.Allocator,
	loc:       runtime.Source_Code_Location,
	max_depth: int,
	reject_unknown_fields: bool,
	codecs:    ^Codec_Registry,
	opaque_commit_count: uint,
	parser:    Parser_State,
	ranges:    Binding_Range_Node_Array,
	builder:   Marshal_Builder,
	path:      [SEMANTIC_MAX_DEPTH + 1]Encode_Diagnostic_Path_Segment,
	path_count: int,
	depth:      int,
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
unmarshal_public_source :: proc(
	state: ^Unmarshal_State,
	source: Unmarshal_Source,
) -> Optional_Source_Range {
	if !source.ok {
		return {}
	}
	return {
		value = source_range(
			state.parser.input, source.value.start, source.value.end,
		),
		ok = true,
	}
}

@(private)
unmarshal_diagnostic_detail :: proc(
	state: ^Unmarshal_State,
	kind: Unmarshal_Data_Error_Kind,
	destination_type: typeid,
	source_kind: Value_Kind,
	source: Unmarshal_Source,
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
		source = unmarshal_public_source(state, source),
		path = unmarshal_path_snapshot(state),
	}
}

@(private)
unmarshal_diagnostic :: proc(
	state: ^Unmarshal_State,
	kind: Unmarshal_Data_Error_Kind,
	destination_type: typeid,
	source_kind: Value_Kind,
	source: Unmarshal_Source = {},
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
unmarshal_source :: proc(source: Source_Byte_Range) -> Unmarshal_Source {
	return {value = source, ok = true}
}

@(private)
unmarshal_push_path :: proc(
	state: ^Unmarshal_State,
	segment: Encode_Diagnostic_Path_Segment,
	source: Source_Byte_Range,
	destination_type: typeid,
	source_kind: Value_Kind,
) -> Unmarshal_Error {
	state.path[state.path_count] = segment
	state.path_count += 1
	state.depth += 1
	if state.depth > state.max_depth {
		err := unmarshal_diagnostic(
			state,
			.Maximum_Depth_Exceeded,
			destination_type,
			source_kind,
			unmarshal_source(source),
		)
		state.depth -= 1
		state.path_count -= 1
		state.path[state.path_count] = {}
		return err
	}
	return nil
}

@(private)
unmarshal_pop_path :: proc(state: ^Unmarshal_State) {
	assert(state.path_count > 0 && state.depth > 0)
	state.depth -= 1
	state.path_count -= 1
	state.path[state.path_count] = {}
}

@(private)
unmarshal_enter_unstable_key :: proc(
	state: ^Unmarshal_State,
	source: Source_Byte_Range,
	destination_type: typeid,
	source_kind: Value_Kind,
) -> Unmarshal_Error {
	state.depth += 1
	if state.depth > state.max_depth {
		err := unmarshal_diagnostic(
			state,
			.Maximum_Depth_Exceeded,
			destination_type,
			source_kind,
			unmarshal_source(source),
		)
		state.depth -= 1
		return err
	}
	return nil
}

@(private)
unmarshal_leave_unstable_key :: proc(state: ^Unmarshal_State) {
	assert(state.depth > 0)
	state.depth -= 1
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
	source: Unmarshal_Source,
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
	source: Unmarshal_Source,
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
	source: Unmarshal_Source,
) -> Unmarshal_Error {
	if unmarshal_codec_registered(state, destination_type) {
		return nil
	}
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
	fallback: Source_Byte_Range,
) -> (
	node_id, binding_range_id: int,
	key_source, value_source: Source_Byte_Range,
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
	if node_id < 0 {
		return -1
	}
	if node_id == 0 {
		return 0
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
	source_range: Source_Byte_Range,
	implicit_zero := false,
) -> Unmarshal_Error {
	kind := unmarshal_value_kind(source)
	optional_source := unmarshal_source(source_range)
	if unmarshal_codec_registered(state, destination.id) {
		if !implicit_zero && !unmarshal_slot_is_exact_zero(destination) {
			return unmarshal_diagnostic(
				state, .Nonzero_Destination_Ownership, destination.id, kind, optional_source,
			)
		}
		return nil
	}
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
		if !implicit_zero && !unmarshal_string_slot_is_zero(destination) {
			return unmarshal_diagnostic(
				state, .Nonzero_Destination_Ownership, destination.id, kind, optional_source,
			)
		}
		return nil
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
			implicit_zero,
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
			implicit_zero,
		); err != nil {
			return err
		}
		return nil
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
			implicit_zero,
		); err != nil {
			return err
		}
		return nil
	case runtime.Type_Info_Slice:
		array, ok := source.(Array)
		if !ok {
			return unmarshal_diagnostic(
				state, .Source_Destination_Kind_Mismatch, destination.id, kind, optional_source,
			)
		}
		if !implicit_zero && !unmarshal_slot_is_exact_zero(destination) {
			return unmarshal_diagnostic(
				state, .Nonzero_Destination_Ownership, destination.id, kind, optional_source,
			)
		}
		metadata := info.variant.(runtime.Type_Info_Slice)
		return unmarshal_preflight_sequence(
			state, array, metadata.elem.id, metadata.elem_size,
			node_id, binding_range_id, source_range,
		)
	case runtime.Type_Info_Dynamic_Array:
		array, ok := source.(Array)
		if !ok {
			return unmarshal_diagnostic(
				state, .Source_Destination_Kind_Mismatch, destination.id, kind, optional_source,
			)
		}
		if !implicit_zero && !unmarshal_slot_is_exact_zero(destination) {
			return unmarshal_diagnostic(
				state, .Nonzero_Destination_Ownership, destination.id, kind, optional_source,
			)
		}
		metadata := info.variant.(runtime.Type_Info_Dynamic_Array)
		return unmarshal_preflight_sequence(
			state, array, metadata.elem.id, metadata.elem_size,
			node_id, binding_range_id, source_range,
		)
	case runtime.Type_Info_Map:
		table, ok := source.(Table)
		if !ok {
			return unmarshal_diagnostic(
				state, .Source_Destination_Kind_Mismatch, destination.id, kind, optional_source,
			)
		}
		if !implicit_zero && !unmarshal_slot_is_exact_zero(destination) {
			return unmarshal_diagnostic(
				state, .Nonzero_Destination_Ownership, destination.id, kind, optional_source,
			)
		}
		metadata := info.variant.(runtime.Type_Info_Map)
		if !unmarshal_map_size_fits(len(table), metadata.map_info) {
			return unmarshal_diagnostic(
				state, .Destination_Size_Overflow, destination.id, kind, optional_source,
			)
		}
		return unmarshal_preflight_map(
			state, table, metadata.value.id,
			unmarshal_child_parent_node(state, node_id), binding_range_id, source_range,
		)
	case runtime.Type_Info_Pointer:
		if !implicit_zero && !unmarshal_slot_is_exact_zero(destination) {
			return unmarshal_diagnostic(
				state, .Nonzero_Destination_Ownership, destination.id, kind, optional_source,
			)
		}
		metadata := info.variant.(runtime.Type_Info_Pointer)
		return unmarshal_preflight_value(
			state, source, any{rawptr(state), metadata.elem.id},
			node_id, binding_range_id, source_range, true,
		)
	case runtime.Type_Info_Union:
		if !implicit_zero && !unmarshal_slot_is_exact_zero(destination) {
			return unmarshal_diagnostic(
				state, .Nonzero_Destination_Ownership, destination.id, kind, optional_source,
			)
		}
		metadata := info.variant.(runtime.Type_Info_Union)
		return unmarshal_preflight_value(
			state, source, any{rawptr(state), metadata.variants[0].id},
			node_id, binding_range_id, source_range, true,
		)
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
	fallback_source: Source_Byte_Range,
	implicit_zero := false,
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
		element_data := rawptr(state)
		if !implicit_zero {
			element_data = rawptr(uintptr(destination.data)+uintptr(index*element_size))
			if element_size == 0 && element_data == nil {
				element_data = rawptr(state)
			}
		}
		element := any{element_data, element_type}
		err := unmarshal_preflight_value(
			state, child, element, child_node_id, child_range_id, child_source, implicit_zero,
		)
		unmarshal_pop_path(state)
		if err != nil {
			return err
		}
	}
	return nil
}

@(private)
unmarshal_preflight_sequence :: proc(
	state: ^Unmarshal_State,
	source: Array,
	element_type: typeid,
	element_size: int,
	parent_node, binding_range_id: int,
	fallback_source: Source_Byte_Range,
) -> Unmarshal_Error {
	if element_size < 0 || len(source) > 0 && element_size > max(int)/len(source) {
		return unmarshal_diagnostic(
			state,
			.Destination_Size_Overflow,
			element_type,
			.Array,
			unmarshal_source(fallback_source),
		)
	}
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
		err := unmarshal_preflight_value(
			state,
			child,
			any{rawptr(state), element_type},
			child_node_id,
			child_range_id,
			child_source,
			true,
		)
		unmarshal_pop_path(state)
		if err != nil {
			return err
		}
	}
	return nil
}

// The pinned runtime's map sizing helpers calculate in uintptr and can wrap
// before allocation. Mirror that exact cell layout with checked int arithmetic
// so size overflow remains a preflight diagnostic rather than an installation
// allocator error. The compiler pin and RTTI feasibility gate intentionally
// make this private coupling reviewable when the runtime layout changes.
@(private)
unmarshal_checked_map_cell_end :: proc(
	base, index: int,
	info: ^runtime.Map_Cell_Info,
) -> (int, bool) {
	if info == nil || info.elements_per_cell == 0 ||
	   info.size_of_cell > uintptr(max(int)) || info.size_of_type > uintptr(max(int)) {
		return 0, false
	}
	elements_per_cell := int(info.elements_per_cell)
	cell_index := index/elements_per_cell
	data_index := index%elements_per_cell
	cell_size := int(info.size_of_cell)
	type_size := int(info.size_of_type)
	if cell_index > 0 && cell_size > max(int)/cell_index {
		return 0, false
	}
	cell_offset := cell_index*cell_size
	if data_index > 0 && type_size > max(int)/data_index {
		return 0, false
	}
	data_offset := data_index*type_size
	if cell_offset > max(int)-data_offset || base > max(int)-(cell_offset+data_offset) {
		return 0, false
	}
	return base+cell_offset+data_offset, true
}

@(private)
unmarshal_checked_map_round :: proc(value: int) -> (int, bool) {
	mask := runtime.MAP_CACHE_LINE_SIZE-1
	if value > max(int)-mask {
		return 0, false
	}
	return (value+mask)&~mask, true
}

@(private)
unmarshal_map_capacity :: proc(count: int) -> (capacity: int, log2: uintptr, ok: bool) {
	if count < 0 {
		return 0, 0, false
	}
	capacity = 8
	log2 = 3
	for count > capacity*75/100 {
		if capacity > max(int)/2 || log2 >= 63 {
			return 0, 0, false
		}
		capacity *= 2
		log2 += 1
	}
	return capacity, log2, true
}

@(private)
unmarshal_map_size_fits :: proc(count: int, info: ^runtime.Map_Info) -> bool {
	if info == nil || info.ks == nil || info.vs == nil {
		return false
	}
	if count == 0 {
		return true
	}
	capacity, _, capacity_ok := unmarshal_map_capacity(count)
	if !capacity_ok {
		return false
	}
	size := 0
	ok: bool
	size, ok = unmarshal_checked_map_cell_end(size, capacity, info.ks)
	if !ok {return false}
	size, ok = unmarshal_checked_map_round(size)
	if !ok {return false}
	size, ok = unmarshal_checked_map_cell_end(size, capacity, info.vs)
	if !ok {return false}
	size, ok = unmarshal_checked_map_round(size)
	if !ok {return false}
	hash_info := runtime.Map_Cell_Info{
		size_of_type = size_of(runtime.Map_Hash),
		align_of_type = align_of(runtime.Map_Hash),
		size_of_cell = runtime.MAP_CACHE_LINE_SIZE,
		elements_per_cell = runtime.MAP_CACHE_LINE_SIZE/size_of(runtime.Map_Hash),
	}
	size, ok = unmarshal_checked_map_cell_end(size, capacity, &hash_info)
	if !ok {return false}
	size, ok = unmarshal_checked_map_round(size)
	if !ok {return false}
	size, ok = unmarshal_checked_map_cell_end(size, 2, info.ks)
	if !ok {return false}
	size, ok = unmarshal_checked_map_round(size)
	if !ok {return false}
	size, ok = unmarshal_checked_map_cell_end(size, 2, info.vs)
	if !ok {return false}
	_, ok = unmarshal_checked_map_round(size)
	return ok
}

@(private)
unmarshal_preflight_map :: proc(
	state: ^Unmarshal_State,
	source: Table,
	value_type: typeid,
	parent_node, parent_range: int,
	fallback_source: Source_Byte_Range,
) -> Unmarshal_Error {
	for entry, index in source {
		node_id, binding_range_id, _, value_source := unmarshal_source_for_entry(
			state, parent_node, parent_range, index, fallback_source,
		)
		if depth_error := unmarshal_enter_unstable_key(
			state, value_source, value_type, unmarshal_value_kind(entry.value),
		); depth_error != nil {
			return depth_error
		}
		err := unmarshal_preflight_value(
			state,
			entry.value,
			any{rawptr(state), value_type},
			node_id,
			binding_range_id,
			value_source,
			true,
		)
		unmarshal_leave_unstable_key(state)
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
	fallback_source: Source_Byte_Range,
	implicit_zero := false,
) -> Unmarshal_Error {
	optional_source := unmarshal_source(fallback_source)
	if parent_node == 0 && parent_range == 0 && fallback_source == (Source_Byte_Range{}) {
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
		field_data := rawptr(state)
		if !implicit_zero {
			field_data = rawptr(uintptr(destination.data)+projected.offset)
		}
		field := any{field_data, projected.source_type}
		err := unmarshal_preflight_value(
			state,
			entry.value,
			field,
			node_id,
			binding_range_id,
			value_source,
			implicit_zero,
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
unmarshal_zero_slot :: proc(destination: any) {
	info := reflect.type_info_base(type_info_of(destination.id))
	bytes := ([^]byte)(destination.data)[:info.size]
	for &byte in bytes {
		byte = 0
	}
}

@(private)
unmarshal_release_map_storage :: proc(
	state: ^Unmarshal_State,
	raw: ^runtime.Raw_Map,
	info: ^runtime.Map_Info,
) {
	if raw == nil {
		return
	}
	if raw.data != 0 && state.builder.gate.mode != .Logical {
		err := runtime.map_free_dynamic(raw^, info, state.loc)
		if state.builder.gate.mode == .Unknown && err == .Mode_Not_Implemented {
			state.builder.gate.mode = .Logical
			err = nil
		} else if state.builder.gate.mode == .Unknown && err == nil {
			state.builder.gate.mode = .Individual
		}
		assert(err == nil, "typed owner allocator violated its destruction contract")
	}
	raw^ = {}
}

@(private)
unmarshal_cleanup_value :: proc(state: ^Unmarshal_State, destination: any) {
	if destination == nil {
		return
	}
	if marshal_is_temporal_type(destination.id) {
		unmarshal_zero_slot(destination)
		return
	}
	info := reflect.type_info_base(type_info_of(destination.id))
	#partial switch metadata in info.variant {
	case runtime.Type_Info_String:
		raw := (^runtime.Raw_String)(destination.data)
		release_owned_memory(
			&state.builder.gate, rawptr(raw.data), raw.len, state.loc,
		)
		raw^ = {}
	case runtime.Type_Info_Struct:
		for field in reflect.struct_fields_zipped(destination.id) {
			unmarshal_cleanup_value(
				state,
				any{rawptr(uintptr(destination.data)+field.offset), field.type.id},
			)
		}
	case runtime.Type_Info_Array:
		for index in 0..<metadata.count {
			data := rawptr(uintptr(destination.data)+uintptr(index*metadata.elem_size))
			if metadata.elem_size == 0 {data = rawptr(state)}
			unmarshal_cleanup_value(state, any{data, metadata.elem.id})
		}
	case runtime.Type_Info_Enumerated_Array:
		for index in 0..<metadata.count {
			data := rawptr(uintptr(destination.data)+uintptr(index*metadata.elem_size))
			if metadata.elem_size == 0 {data = rawptr(state)}
			unmarshal_cleanup_value(state, any{data, metadata.elem.id})
		}
	case runtime.Type_Info_Slice:
		raw := (^runtime.Raw_Slice)(destination.data)
		for index in 0..<raw.len {
			data := rawptr(uintptr(raw.data)+uintptr(index*metadata.elem_size))
			if metadata.elem_size == 0 {data = rawptr(state)}
			unmarshal_cleanup_value(state, any{data, metadata.elem.id})
		}
		release_owned_memory(
			&state.builder.gate,
			raw.data,
			raw.len*metadata.elem_size,
			state.loc,
		)
		raw^ = {}
	case runtime.Type_Info_Dynamic_Array:
		raw := (^runtime.Raw_Dynamic_Array)(destination.data)
		for index in 0..<raw.len {
			data := rawptr(uintptr(raw.data)+uintptr(index*metadata.elem_size))
			if metadata.elem_size == 0 {data = rawptr(state)}
			unmarshal_cleanup_value(state, any{data, metadata.elem.id})
		}
		release_owned_memory(
			&state.builder.gate,
			raw.data,
			raw.cap*metadata.elem_size,
			state.loc,
		)
		raw^ = {}
	case runtime.Type_Info_Map:
		iterator := 0
		for {
			key, value, ok := reflect.iterate_map(destination, &iterator)
			if !ok {break}
			unmarshal_cleanup_value(state, key)
			unmarshal_cleanup_value(state, value)
		}
		unmarshal_release_map_storage(
			state, (^runtime.Raw_Map)(destination.data), metadata.map_info,
		)
	case runtime.Type_Info_Pointer:
		memory := (^rawptr)(destination.data)^
		if memory != nil {
			unmarshal_cleanup_value(state, any{memory, metadata.elem.id})
			size := max(metadata.elem.size, 1)
			release_owned_memory(&state.builder.gate, memory, size, state.loc)
		}
		(^rawptr)(destination.data)^ = nil
	case runtime.Type_Info_Union:
		active := reflect.union_variant_typeid(destination)
		if active != nil {
			unmarshal_cleanup_value(state, any{destination.data, active})
		}
		unmarshal_zero_slot(destination)
	case:
		unmarshal_zero_slot(destination)
	}
}

@(private)
unmarshal_install_storage :: proc(
	state: ^Unmarshal_State,
	size, alignment: int,
) -> (rawptr, Unmarshal_Error) {
	if size == 0 {
		return nil, nil
	}
	memory, err := allocator_allocate_aligned(
		size, alignment, state.allocator, true, state.loc,
	)
	if err != nil {
		return nil, err
	}
	if memory == nil {
		return nil, runtime.Allocator_Error.Out_Of_Memory
	}
	return memory, nil
}

@(private)
unmarshal_assign_sequence :: proc(
	state: ^Unmarshal_State,
	source: Array,
	data: rawptr,
	element_type: typeid,
	element_size: int,
	parent_node, parent_range: int,
	fallback_source: Source_Byte_Range,
) -> Unmarshal_Error {
	for child, index in source {
		child_node_id, child_range_id, _, child_source := unmarshal_source_for_entry(
			state, parent_node, parent_range, index, fallback_source,
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
		element_data := rawptr(uintptr(data)+uintptr(index*element_size))
		if element_size == 0 {element_data = rawptr(state)}
		err := unmarshal_assign_value(
			state,
			child,
			any{element_data, element_type},
			child_node_id,
			child_range_id,
			unmarshal_source(child_source),
		)
		unmarshal_pop_path(state)
		if err != nil {
			return err
		}
	}
	return nil
}

@(private)
unmarshal_remove_map_entry :: proc(
	state: ^Unmarshal_State,
	raw_map: ^runtime.Raw_Map,
	metadata: runtime.Type_Info_Map,
	key: string,
	cleanup_value: bool,
) {
	lookup := transmute(runtime.Raw_String)key
	old_key_address, old_value_address, found := runtime.map_erase_dynamic(
		raw_map, metadata.map_info, uintptr(&lookup),
	)
	assert(found)
	old_key := (^runtime.Raw_String)(rawptr(old_key_address))
	old_value := any{rawptr(old_value_address), metadata.value.id}
	if cleanup_value {
		unmarshal_cleanup_value(state, old_value)
	} else {
		assert(unmarshal_slot_is_exact_zero(old_value))
	}
	release_owned_memory(
		&state.builder.gate, rawptr(old_key.data), old_key.len, state.loc,
	)
	old_key^ = {}
	unmarshal_zero_slot(old_value)
}

@(private)
unmarshal_remove_map_entries :: proc(
	state: ^Unmarshal_State,
	source: Table,
	raw_map: ^runtime.Raw_Map,
	metadata: runtime.Type_Info_Map,
	first, end: int,
	cleanup_first: bool = false,
) {
	for index in first..<end {
		unmarshal_remove_map_entry(
			state,
			raw_map,
			metadata,
			source[index].key,
			cleanup_first && index == first,
		)
	}
}

@(private)
unmarshal_assign_map :: proc(
	state: ^Unmarshal_State,
	source: Table,
	destination: any,
	metadata: runtime.Type_Info_Map,
	parent_node, parent_range: int,
	fallback_source: Source_Byte_Range,
) -> Unmarshal_Error {
	raw_map := (^runtime.Raw_Map)(destination.data)
	if len(source) == 0 {
		raw_map.allocator = state.allocator
		return nil
	}

	_, log2_capacity, capacity_ok := unmarshal_map_capacity(len(source))
	assert(capacity_ok)
	initialized, allocation_error := runtime.map_alloc_dynamic(
		metadata.map_info, log2_capacity, state.allocator, state.loc,
	)
	if allocation_error != nil {
		return allocation_error
	}
	if initialized.data == 0 {
		return runtime.Allocator_Error.Out_Of_Memory
	}
	raw_map^ = initialized

	value_info := reflect.type_info_base(type_info_of(metadata.value.id))
	zero_memory, zero_error := unmarshal_install_storage(
		state, value_info.size, value_info.align,
	)
	if zero_error != nil {
		return zero_error
	}
	zero_data := zero_memory
	if zero_data == nil {zero_data = rawptr(state)}
	staged_count := 0
	for entry in source {
		owned_key, key_error := clone_owned_string(entry.key, state.allocator, state.loc)
		if key_error != nil {
			unmarshal_remove_map_entries(
				state, source, raw_map, metadata, 0, staged_count,
			)
			release_owned_memory(
				&state.builder.gate, zero_memory, value_info.size, state.loc,
			)
			return key_error.(runtime.Allocator_Error)
		}
		key_raw := transmute(runtime.Raw_String)owned_key
		_, insert_error := runtime.__dynamic_map_set_without_hash(
			raw_map,
			metadata.map_info,
			&key_raw,
			zero_data,
			state.loc,
		)
		if insert_error != nil {
			release_owned_memory(
				&state.builder.gate, raw_data(owned_key), len(owned_key), state.loc,
			)
			unmarshal_remove_map_entries(
				state, source, raw_map, metadata, 0, staged_count,
			)
			release_owned_memory(
				&state.builder.gate, zero_memory, value_info.size, state.loc,
			)
			return insert_error
		}
		key_raw = {}
		staged_count += 1
	}
	release_owned_memory(
		&state.builder.gate, zero_memory, value_info.size, state.loc,
	)

	for entry, index in source {
		lookup := transmute(runtime.Raw_String)entry.key
		hash := metadata.map_info.key_hasher(&lookup, runtime.map_seed(raw_map^))
		value_data := runtime.__dynamic_map_get(
			raw_map, metadata.map_info, hash, &lookup,
		)
		assert(value_data != nil)
		value_slot := any{value_data, metadata.value.id}
		node_id, binding_range_id, _, value_source := unmarshal_source_for_entry(
			state, parent_node, parent_range, index, fallback_source,
		)
		if depth_error := unmarshal_enter_unstable_key(
			state, value_source, metadata.value.id, unmarshal_value_kind(entry.value),
		); depth_error != nil {
			unmarshal_remove_map_entries(
				state, source, raw_map, metadata, index, len(source),
			)
			return depth_error
		}
		commit_before := state.opaque_commit_count
		install_error := unmarshal_assign_value(
			state,
			entry.value,
			value_slot,
			node_id,
			binding_range_id,
			unmarshal_source(value_source),
		)
		unmarshal_leave_unstable_key(state)
		if install_error != nil {
			opaque_committed := state.opaque_commit_count != commit_before
			first_removal := index
			if opaque_committed {
				first_removal += 1
			}
			unmarshal_remove_map_entries(
				state,
				source,
				raw_map,
				metadata,
				first_removal,
				len(source),
				!opaque_committed,
			)
			return install_error
		}
	}
	return nil
}

@(private)
unmarshal_assign_value :: proc(
	state: ^Unmarshal_State,
	source: Value,
	destination: any,
	node_id, binding_range_id: int,
	source_range: Unmarshal_Source,
) -> Unmarshal_Error {
	if codec_error, handled := unmarshal_codec_value(
		state, source, destination, source_range,
	); handled {
		return codec_error
	}
	if destination.id == typeid_of(temporal.Offset_Date_Time) {
		(^temporal.Offset_Date_Time)(destination.data)^ = source.(temporal.Offset_Date_Time)
		return nil
	}
	if destination.id == typeid_of(temporal.Local_Date_Time) {
		(^temporal.Local_Date_Time)(destination.data)^ = source.(temporal.Local_Date_Time)
		return nil
	}
	if destination.id == typeid_of(temporal.Local_Date) {
		(^temporal.Local_Date)(destination.data)^ = source.(temporal.Local_Date)
		return nil
	}
	if destination.id == typeid_of(temporal.Local_Time) {
		(^temporal.Local_Time)(destination.data)^ = source.(temporal.Local_Time)
		return nil
	}
	fallback_source := Source_Byte_Range{}
	if source_range.ok {fallback_source = source_range.value}
	info := reflect.type_info_base(type_info_of(destination.id))
	#partial switch metadata in info.variant {
	case runtime.Type_Info_String:
		owned, err := clone_owned_string(string(source.(String)), state.allocator, state.loc)
		if err != nil {return err.(runtime.Allocator_Error)}
		(^runtime.Raw_String)(destination.data)^ = transmute(runtime.Raw_String)owned
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
		return unmarshal_assign_struct(
			state,
			source.(Table),
			destination,
			unmarshal_child_parent_node(state, node_id),
			binding_range_id,
			fallback_source,
		)
	case runtime.Type_Info_Array:
		return unmarshal_assign_sequence(
			state,
			source.(Array),
			destination.data,
			metadata.elem.id,
			metadata.elem_size,
			node_id,
			binding_range_id,
			fallback_source,
		)
	case runtime.Type_Info_Enumerated_Array:
		return unmarshal_assign_sequence(
			state,
			source.(Array),
			destination.data,
			metadata.elem.id,
			metadata.elem_size,
			node_id,
			binding_range_id,
			fallback_source,
		)
	case runtime.Type_Info_Slice:
		array := source.(Array)
		size := len(array)*metadata.elem_size
		memory, err := unmarshal_install_storage(state, size, metadata.elem.align)
		if err != nil {return err}
		raw := (^runtime.Raw_Slice)(destination.data)
		raw^ = {data = memory, len = len(array)}
		return unmarshal_assign_sequence(
			state, array, memory, metadata.elem.id, metadata.elem_size,
			node_id, binding_range_id, fallback_source,
		)
	case runtime.Type_Info_Dynamic_Array:
		array := source.(Array)
		size := len(array)*metadata.elem_size
		memory, err := unmarshal_install_storage(state, size, metadata.elem.align)
		if err != nil {return err}
		raw := (^runtime.Raw_Dynamic_Array)(destination.data)
		raw^ = {
			data = memory,
			len = len(array),
			cap = len(array),
			allocator = state.allocator,
		}
		return unmarshal_assign_sequence(
			state, array, memory, metadata.elem.id, metadata.elem_size,
			node_id, binding_range_id, fallback_source,
		)
	case runtime.Type_Info_Map:
		return unmarshal_assign_map(
			state,
			source.(Table),
			destination,
			metadata,
			unmarshal_child_parent_node(state, node_id),
			binding_range_id,
			fallback_source,
		)
	case runtime.Type_Info_Pointer:
		size := max(metadata.elem.size, 1)
		memory, err := unmarshal_install_storage(state, size, metadata.elem.align)
		if err != nil {return err}
		(^rawptr)(destination.data)^ = memory
		return unmarshal_assign_value(
			state,
			source,
			any{memory, metadata.elem.id},
			node_id,
			binding_range_id,
			source_range,
		)
	case runtime.Type_Info_Union:
		variant := metadata.variants[0]
		if !reflect.type_info_union_is_pure_maybe(metadata) {
			reflect.set_union_variant_typeid(destination, variant.id)
		}
		return unmarshal_assign_value(
			state,
			source,
			any{destination.data, variant.id},
			node_id,
			binding_range_id,
			source_range,
		)
	case:
		unreachable()
	}
	return nil
}

@(private)
unmarshal_assign_struct :: proc(
	state: ^Unmarshal_State,
	source: Table,
	destination: any,
	parent_node, parent_range: int,
	fallback_source: Source_Byte_Range,
) -> Unmarshal_Error {
	parser := Marshal_Builder{max_depth = SEMANTIC_MAX_DEPTH}
	for entry, index in source {
		stable_name, field, matched := marshal_projected_field_value_by_name(
			&parser, destination, entry.key,
		)
		if !matched {
			continue
		}
		node_id, binding_range_id, _, value_source := unmarshal_source_for_entry(
			state, parent_node, parent_range, index, fallback_source,
		)
		if path_error := unmarshal_push_path(
			state,
			stable_name,
			value_source,
			field.id,
			unmarshal_value_kind(entry.value),
		); path_error != nil {
			return path_error
		}
		err := unmarshal_assign_value(
			state,
			entry.value,
			field,
			node_id,
			binding_range_id,
			unmarshal_source(value_source),
		)
		unmarshal_pop_path(state)
		if err != nil {
			return err
		}
	}
	return nil
}

@(private)
unmarshal_root_shape_is_valid :: proc(
	state: ^Unmarshal_State,
	destination_type: typeid,
) -> bool {
	if unmarshal_codec_registered(state, destination_type) {
		return true
	}
	current := destination_type
	for _ in 0..=SEMANTIC_MAX_DEPTH {
		info := reflect.type_info_base(type_info_of(current))
		#partial switch metadata in info.variant {
		case runtime.Type_Info_Struct:
			return .raw_union not_in metadata.flags
		case runtime.Type_Info_Map:
			key_info := reflect.type_info_base(type_info_of(metadata.key.id))
			key, ok := key_info.variant.(runtime.Type_Info_String)
			return ok && !key.is_cstring && key.encoding == .UTF_8
		case runtime.Type_Info_Pointer:
			if metadata.elem == nil {return false}
			current = metadata.elem.id
			if unmarshal_codec_registered(state, current) {return true}
			continue
		case runtime.Type_Info_Union:
			if metadata.no_nil || len(metadata.variants) != 1 {return false}
			current = metadata.variants[0].id
			if unmarshal_codec_registered(state, current) {return true}
			continue
		}
		return false
	}
	return false
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
		codecs = options.codecs,
	}
	state.parser.input = input
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
	if !unmarshal_root_shape_is_valid(&state, destination_type) {
		return unmarshal_diagnostic(
			&state, .Invalid_Root_Shape, destination_type, .Table,
		)
	}
	if declared_error := unmarshal_validate_declared_type(
		&state, destination_type, {},
	); declared_error != nil {
		return declared_error
	}
	root := Value(document.root)
	if preflight_error := unmarshal_preflight_value(
		&state, root, destination_value, 0, 0, {},
	); preflight_error != nil {
		return preflight_error
	}
	return unmarshal_assign_value(&state, root, destination_value, 0, 0, {})
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

package toml

import "base:runtime"
import "core:mem"
import "core:reflect"
import "core:strings"

@(private)
Marshal_Reference_Kind :: enum u8 {
	Pointer,
	Slice,
	Dynamic_Array,
	Map,
	Any,
}

@(private)
Marshal_Active_Reference :: struct {
	identity: rawptr,
	kind:     Marshal_Reference_Kind,
	extent:   int,
}

@(private)
marshal_active_references_destroy :: proc(builder: ^Marshal_Builder) {
	if builder == nil {
		return
	}
	release_owned_memory(
		&builder.gate,
		raw_data(builder.active_references),
		cap(builder.active_references)*size_of(Marshal_Active_Reference),
		builder.loc,
	)
	builder.active_references = nil
}

@(private)
marshal_active_references_grow :: proc(builder: ^Marshal_Builder) -> Marshal_Error {
	old_capacity := cap(builder.active_references)
	new_capacity := 8
	if old_capacity > 0 {
		if old_capacity > max(int)/2 {
			return marshal_limit_error(builder, .Size_Overflow)
		}
		new_capacity = old_capacity*2
	}
	raw, storage_error := make_owned_dynamic_array_storage(
		new_capacity,
		size_of(Marshal_Active_Reference),
		builder.allocator,
		builder.loc,
	)
	if storage_error != nil {
		if allocator_error, ok := storage_error.(runtime.Allocator_Error); ok {
			return allocator_error
		}
		return marshal_limit_error(builder, .Size_Overflow)
	}
	old_count := len(builder.active_references)
	grown := transmute([dynamic]Marshal_Active_Reference)raw
	if old_count > 0 {
		mem.copy_non_overlapping(
			raw_data(grown),
			raw_data(builder.active_references),
			old_count*size_of(Marshal_Active_Reference),
		)
	}
	release_owned_memory(
		&builder.gate,
		raw_data(builder.active_references),
		old_capacity*size_of(Marshal_Active_Reference),
		builder.loc,
	)
	descriptor := transmute(runtime.Raw_Dynamic_Array)grown
	descriptor.len = old_count
	builder.active_references = transmute([dynamic]Marshal_Active_Reference)descriptor
	return nil
}

@(private)
marshal_reference_enter :: proc(
	builder: ^Marshal_Builder,
	identity: rawptr,
	kind: Marshal_Reference_Kind,
	source_type: typeid,
	extent := 0,
) -> (bool, Marshal_Error) {
	if identity == nil {
		return false, nil
	}
	for reference in builder.active_references {
		if reference.identity == identity && reference.kind == kind &&
		   reference.extent == extent {
			return false, marshal_data_error(builder, .Active_Recursion_Cycle, source_type)
		}
	}
	if len(builder.active_references) == cap(builder.active_references) {
		if grow_error := marshal_active_references_grow(builder); grow_error != nil {
			return false, grow_error
		}
	}
	append(
		&builder.active_references,
		Marshal_Active_Reference{identity, kind, extent},
	)
	return true, nil
}

@(private)
marshal_reference_leave :: proc(builder: ^Marshal_Builder, entered: bool) {
	if !entered {
		return
	}
	assert(len(builder.active_references) > 0)
	builder.active_references[len(builder.active_references)-1] = {}
	pop(&builder.active_references)
}

@(private)
marshal_validate_map_key_type :: proc(
	builder: ^Marshal_Builder,
	key_type: typeid,
) -> Marshal_Error {
	info := reflect.type_info_base(type_info_of(key_type))
	metadata, ok := info.variant.(runtime.Type_Info_String)
	if !ok || metadata.is_cstring || metadata.encoding != .UTF_8 {
		return marshal_data_error(builder, .Unsupported_Map_Key_Type, key_type)
	}
	return nil
}

@(private)
marshal_declared_type_step :: proc(
	builder: ^Marshal_Builder,
	source_type: typeid,
) -> (next: typeid, terminal: bool, err: Marshal_Error) {
	if source_type == nil {
		return nil, true, marshal_data_error(builder, .Unsupported_Type, source_type)
	}
	if marshal_is_temporal_type(source_type) {
		return nil, true, nil
	}
	if marshal_is_semantic_binding_type(source_type) {
		return nil, true, marshal_data_error(builder, .Unsupported_Type, source_type)
	}
	info := reflect.type_info_base(type_info_of(source_type))
	#partial switch metadata in info.variant {
	case runtime.Type_Info_String:
		if metadata.is_cstring || metadata.encoding != .UTF_8 {
			return nil, true, marshal_data_error(builder, .Unsupported_Type, source_type)
		}
		return nil, true, nil
	case runtime.Type_Info_Boolean:
		return nil, true, nil
	case runtime.Type_Info_Integer:
		if info.size > size_of(i128) {
			return nil, true, marshal_data_error(builder, .Unsupported_Type, source_type)
		}
		return nil, true, nil
	case runtime.Type_Info_Float:
		if info.size != size_of(f16) && info.size != size_of(f32) && info.size != size_of(f64) {
			return nil, true, marshal_data_error(builder, .Unsupported_Type, source_type)
		}
		return nil, true, nil
	case runtime.Type_Info_Array:
		return metadata.elem.id, false, nil
	case runtime.Type_Info_Enumerated_Array:
		return metadata.elem.id, false, nil
	case runtime.Type_Info_Slice:
		return metadata.elem.id, false, nil
	case runtime.Type_Info_Dynamic_Array:
		return metadata.elem.id, false, nil
	case runtime.Type_Info_Map:
		if key_error := marshal_validate_map_key_type(
			builder,
			metadata.key.id,
		); key_error != nil {
			return nil, true, key_error
		}
		return metadata.value.id, false, nil
	case runtime.Type_Info_Pointer:
		if metadata.elem == nil {
			return nil, true, marshal_data_error(builder, .Unsupported_Type, source_type)
		}
		return metadata.elem.id, false, nil
	case runtime.Type_Info_Union:
		if metadata.no_nil || len(metadata.variants) != 1 {
			return nil, true, marshal_data_error(builder, .Unsupported_Type, source_type)
		}
		return metadata.variants[0].id, false, nil
	case runtime.Type_Info_Any:
		return nil, true, nil
	case runtime.Type_Info_Struct:
		if .raw_union in metadata.flags {
			return nil, true, marshal_data_error(builder, .Unsupported_Type, source_type)
		}
		plan, plan_error := marshal_struct_plan_build(builder, source_type)
		if plan_error != nil {
			return nil, true, plan_error
		}
		marshal_struct_plan_destroy(builder, &plan)
		return nil, true, nil
	}
	return nil, true, marshal_data_error(builder, .Unsupported_Type, source_type)
}

@(private)
marshal_validate_declared_type :: proc(
	builder: ^Marshal_Builder,
	source_type: typeid,
) -> Marshal_Error {
	tortoise := source_type
	current := source_type
	power := 1
	cycle_length := 0
	for {
		next, terminal, step_error := marshal_declared_type_step(builder, current)
		if step_error != nil || terminal {
			return step_error
		}
		current = next
		cycle_length += 1
		if current == tortoise {
			return nil
		}
		if cycle_length == power {
			tortoise = current
			if power > max(int)/2 {
				return marshal_limit_error(builder, .Size_Overflow)
			}
			power *= 2
			cycle_length = 0
		}
	}
}

@(private)
Marshal_Sequence_View :: struct {
	data:         rawptr,
	count:        int,
	element_type: typeid,
	element_size: int,
	reference:    rawptr,
	reference_kind: Marshal_Reference_Kind,
}

@(private)
marshal_sequence_view :: proc(
	builder: ^Marshal_Builder,
	value: any,
) -> (Marshal_Sequence_View, Marshal_Error) {
	info := reflect.type_info_base(type_info_of(value.id))
	#partial switch metadata in info.variant {
	case runtime.Type_Info_Array:
		return {
			data = value.data,
			count = metadata.count,
			element_type = metadata.elem.id,
			element_size = metadata.elem_size,
		}, nil
	case runtime.Type_Info_Enumerated_Array:
		return {
			data = value.data,
			count = metadata.count,
			element_type = metadata.elem.id,
			element_size = metadata.elem_size,
		}, nil
	case runtime.Type_Info_Slice:
		raw := (^mem.Raw_Slice)(value.data)^
		if raw.len < 0 || (raw.len > 0 && raw.data == nil && metadata.elem_size > 0) {
			return {}, marshal_data_error(builder, .Invalid_Container, value.id)
		}
		return {
			data = raw.data,
			count = raw.len,
			element_type = metadata.elem.id,
			element_size = metadata.elem_size,
			reference = raw.data,
			reference_kind = .Slice,
		}, nil
	case runtime.Type_Info_Dynamic_Array:
		raw := (^mem.Raw_Dynamic_Array)(value.data)^
		if raw.allocator.procedure == nil || raw.len < 0 || raw.cap < 0 ||
		   (metadata.elem_size > 0 && raw.cap < raw.len) ||
		   (raw.cap > 0 && raw.data == nil && metadata.elem_size > 0) {
			return {}, marshal_data_error(builder, .Invalid_Container, value.id)
		}
		return {
			data = raw.data,
			count = raw.len,
			element_type = metadata.elem.id,
			element_size = metadata.elem_size,
			reference = raw.data,
			reference_kind = .Dynamic_Array,
		}, nil
	}
	return {}, marshal_data_error(builder, .Unsupported_Type, value.id)
}

@(private)
marshal_sequence_value :: proc(
	builder: ^Marshal_Builder,
	value: any,
) -> (Value, Marshal_Error) {
	view, view_error := marshal_sequence_view(builder, value)
	if view_error != nil {
		return {}, view_error
	}
	if type_error := marshal_validate_declared_type(builder, view.element_type); type_error != nil {
		return {}, type_error
	}
	if view.count > 0 && view.element_size > max(int)/view.count {
		return {}, marshal_limit_error(builder, .Size_Overflow)
	}
	entered, reference_error := marshal_reference_enter(
		builder,
		view.reference,
		view.reference_kind,
		value.id,
		view.count,
	)
	if reference_error != nil {
		return {}, reference_error
	}
	defer marshal_reference_leave(builder, entered)

	array, array_error := make_owned_array(view.count, builder.allocator, builder.loc)
	if array_error != nil {
		if allocator_error, ok := array_error.(runtime.Allocator_Error); ok {
			return {}, allocator_error
		}
		return {}, marshal_limit_error(builder, .Size_Overflow)
	}
	for index in 0..<view.count {
		if path_error := marshal_push_path(builder, Path_Index(index)); path_error != nil {
			owned := Value(array)
			destroy_value_with_gate(&owned, &builder.gate, builder.loc)
			return {}, path_error
		}
		element_data := rawptr(uintptr(view.data)+uintptr(index*view.element_size))
		if view.element_size == 0 && element_data == nil {
			element_data = rawptr(builder)
		}
		element := any{element_data, view.element_type}
		converted, conversion_error := marshal_reflected_value(builder, element)
		marshal_pop_path(builder)
		if conversion_error != nil {
			owned := Value(array)
			destroy_value_with_gate(&owned, &builder.gate, builder.loc)
			return {}, conversion_error
		}
		array[index] = converted
	}
	return Value(array), nil
}

@(private)
Marshal_Map_Plan_Entry :: struct {
	key:      string,
	path_key: string,
	value:    any,
}

@(private)
Marshal_Map_Plan :: struct {
	entries: [dynamic]Marshal_Map_Plan_Entry,
}

@(private)
marshal_map_plan_destroy :: proc(builder: ^Marshal_Builder, plan: ^Marshal_Map_Plan) {
	if plan == nil {
		return
	}
	for &entry in plan.entries {
		release_owned_memory(&builder.gate, raw_data(entry.key), len(entry.key), builder.loc)
		entry.key = ""
	}
	release_owned_memory(
		&builder.gate,
		raw_data(plan.entries),
		cap(plan.entries)*size_of(Marshal_Map_Plan_Entry),
		builder.loc,
	)
	plan^ = {}
}

@(private)
marshal_map_plan_build :: proc(
	builder: ^Marshal_Builder,
	value: any,
	metadata: runtime.Type_Info_Map,
	count: int,
) -> (plan: Marshal_Map_Plan, err: Marshal_Error) {
	raw, storage_error := make_owned_dynamic_array_storage(
		count,
		size_of(Marshal_Map_Plan_Entry),
		builder.allocator,
		builder.loc,
	)
	if storage_error != nil {
		if allocator_error, ok := storage_error.(runtime.Allocator_Error); ok {
			return {}, allocator_error
		}
		return {}, marshal_limit_error(builder, .Size_Overflow)
	}
	plan.entries = transmute([dynamic]Marshal_Map_Plan_Entry)raw
	iterator := 0
	actual_count := 0
	for actual_count < count {
		key_value, mapped_value, ok := reflect.iterate_map(value, &iterator)
		if !ok {
			break
		}
		key, valid := reflect.as_string(key_value)
		if !valid {
			err = marshal_data_error(builder, .Unsupported_Map_Key_Type, metadata.key.id)
			marshal_map_plan_destroy(builder, &plan)
			return {}, err
		}
		plan.entries[actual_count] = {
			path_key = key,
			value = mapped_value,
		}
		actual_count += 1
	}
	if _, _, extra := reflect.iterate_map(value, &iterator); extra || actual_count != count {
		err = marshal_data_error_detail(
			builder,
			.Invalid_Container,
			value.id,
			nil,
			.None,
			count,
			actual_count+int(extra),
		)
		marshal_map_plan_destroy(builder, &plan)
		return {}, err
	}
	for index in 1..<len(plan.entries) {
		cursor := index
		for cursor > 0 && strings.compare(
			plan.entries[cursor].path_key,
			plan.entries[cursor-1].path_key,
		) < 0 {
			plan.entries[cursor], plan.entries[cursor-1] =
				plan.entries[cursor-1], plan.entries[cursor]
			cursor -= 1
		}
	}
	for &entry in plan.entries {
		if path_error := marshal_push_path(builder, entry.path_key); path_error != nil {
			marshal_map_plan_destroy(builder, &plan)
			return {}, path_error
		}
		entry.key, err = marshal_clone_text(builder, entry.path_key, metadata.key.id)
		marshal_pop_path(builder)
		if err != nil {
			marshal_map_plan_destroy(builder, &plan)
			return {}, err
		}
	}
	for index in 1..<len(plan.entries) {
		if plan.entries[index-1].key == plan.entries[index].key {
			if path_error := marshal_push_path(
				builder,
				plan.entries[index].path_key,
			); path_error != nil {
				marshal_map_plan_destroy(builder, &plan)
				return {}, path_error
			}
			err = marshal_data_error(
				builder,
				.Converted_Map_Key_Collision,
				metadata.key.id,
			)
			marshal_pop_path(builder)
			marshal_map_plan_destroy(builder, &plan)
			return {}, err
		}
	}
	return
}

@(private)
marshal_map_table :: proc(
	builder: ^Marshal_Builder,
	value: any,
) -> (Table, Marshal_Error) {
	info := reflect.type_info_base(type_info_of(value.id))
	metadata, ok := info.variant.(runtime.Type_Info_Map)
	if !ok {
		return {}, marshal_data_error(builder, .Unsupported_Type, value.id)
	}
	if key_error := marshal_validate_map_key_type(builder, metadata.key.id); key_error != nil {
		return {}, key_error
	}
	if value_type_error := marshal_validate_declared_type(
		builder,
		metadata.value.id,
	); value_type_error != nil {
		return {}, value_type_error
	}
	raw_map := (^mem.Raw_Map)(value.data)^
	if raw_map.allocator.procedure == nil {
		return {}, marshal_data_error(builder, .Invalid_Container, value.id)
	}
	if raw_map.len > uintptr(max(int)) {
		return {}, marshal_limit_error(builder, .Size_Overflow)
	}
	count := int(raw_map.len)
	identity := rawptr(runtime.map_data(raw_map))
	entered, reference_error := marshal_reference_enter(
		builder,
		identity,
		.Map,
		value.id,
	)
	if reference_error != nil {
		return {}, reference_error
	}
	defer marshal_reference_leave(builder, entered)

	plan, plan_error := marshal_map_plan_build(builder, value, metadata, count)
	if plan_error != nil {
		return {}, plan_error
	}
	defer marshal_map_plan_destroy(builder, &plan)
	table, table_error := make_owned_table(count, builder.allocator, builder.loc)
	if table_error != nil {
		if allocator_error, allocation_error := table_error.(runtime.Allocator_Error); allocation_error {
			return {}, allocator_error
		}
		return {}, marshal_limit_error(builder, .Size_Overflow)
	}
	for &entry, index in plan.entries {
		table[index].key = entry.key
		entry.key = ""
		if path_error := marshal_push_path(builder, entry.path_key); path_error != nil {
			destroy_table_with_gate(&table, &builder.gate, builder.loc)
			return {}, path_error
		}
		converted, conversion_error := marshal_reflected_value(builder, entry.value)
		marshal_pop_path(builder)
		if conversion_error != nil {
			destroy_table_with_gate(&table, &builder.gate, builder.loc)
			return {}, conversion_error
		}
		table[index].value = converted
	}
	return table, nil
}

@(private)
marshal_pointer_value :: proc(
	builder: ^Marshal_Builder,
	value: any,
) -> (Value, Marshal_Error) {
	info := reflect.type_info_base(type_info_of(value.id))
	metadata, ok := info.variant.(runtime.Type_Info_Pointer)
	if !ok || metadata.elem == nil {
		return {}, marshal_data_error(builder, .Unsupported_Type, value.id)
	}
	identity := (^rawptr)(value.data)^
	if identity == nil {
		return {}, marshal_data_error(builder, .Unsupported_Nil, value.id)
	}
	if type_error := marshal_validate_declared_type(builder, metadata.elem.id); type_error != nil {
		return {}, type_error
	}
	entered, reference_error := marshal_reference_enter(
		builder,
		identity,
		.Pointer,
		value.id,
	)
	if reference_error != nil {
		return {}, reference_error
	}
	defer marshal_reference_leave(builder, entered)
	return marshal_reflected_value(builder, reflect.deref(value))
}

@(private)
marshal_union_value :: proc(
	builder: ^Marshal_Builder,
	value: any,
) -> (Value, Marshal_Error) {
	info := reflect.type_info_base(type_info_of(value.id))
	metadata, ok := info.variant.(runtime.Type_Info_Union)
	if !ok || metadata.no_nil || len(metadata.variants) != 1 {
		return {}, marshal_data_error(builder, .Unsupported_Type, value.id)
	}
	is_nil := reflect.union_variant_typeid(value) == nil
	if reflect.type_info_union_is_pure_maybe(metadata) {
		is_nil = (^rawptr)(value.data)^ == nil
	}
	if is_nil {
		return {}, marshal_data_error(builder, .Unsupported_Nil, value.id)
	}
	if type_error := marshal_validate_declared_type(
		builder,
		metadata.variants[0].id,
	); type_error != nil {
		return {}, type_error
	}
	return marshal_reflected_value(builder, reflect.get_union_variant(value))
}

@(private)
marshal_any_value :: proc(
	builder: ^Marshal_Builder,
	value: any,
) -> (Value, Marshal_Error) {
	unwrapped := (^any)(value.data)^
	if unwrapped == nil {
		return {}, marshal_data_error(builder, .Unsupported_Nil, value.id)
	}
	entered, reference_error := marshal_reference_enter(
		builder,
		value.data,
		.Any,
		value.id,
	)
	if reference_error != nil {
		return {}, reference_error
	}
	defer marshal_reference_leave(builder, entered)
	return marshal_reflected_value(builder, unwrapped)
}

@(private)
marshal_root_table :: proc(
	builder: ^Marshal_Builder,
	value: any,
) -> (Table, Marshal_Error) {
	if value == nil {
		zero_type: typeid
		return {}, marshal_data_error(builder, .Unsupported_Nil, zero_type)
	}
	if marshal_is_temporal_type(value.id) || marshal_is_semantic_binding_type(value.id) {
		return {}, marshal_data_error(builder, .Invalid_Root_Shape, value.id)
	}
	info := reflect.type_info_base(type_info_of(value.id))
	#partial switch metadata in info.variant {
	case runtime.Type_Info_Pointer:
		if metadata.elem == nil {
			return {}, marshal_data_error(builder, .Invalid_Root_Shape, value.id)
		}
		identity := (^rawptr)(value.data)^
		if identity == nil {
			return {}, marshal_data_error(builder, .Unsupported_Nil, value.id)
		}
		entered, reference_error := marshal_reference_enter(
			builder, identity, .Pointer, value.id,
		)
		if reference_error != nil {
			return {}, reference_error
		}
		defer marshal_reference_leave(builder, entered)
		return marshal_root_table(builder, reflect.deref(value))
	case runtime.Type_Info_Union:
		if metadata.no_nil || len(metadata.variants) != 1 {
			return {}, marshal_data_error(builder, .Invalid_Root_Shape, value.id)
		}
		is_nil := reflect.union_variant_typeid(value) == nil
		if reflect.type_info_union_is_pure_maybe(metadata) {
			is_nil = (^rawptr)(value.data)^ == nil
		}
		if is_nil {
			return {}, marshal_data_error(builder, .Unsupported_Nil, value.id)
		}
		return marshal_root_table(builder, reflect.get_union_variant(value))
	case runtime.Type_Info_Any:
		unwrapped := (^any)(value.data)^
		if unwrapped == nil {
			return {}, marshal_data_error(builder, .Unsupported_Nil, value.id)
		}
		entered, reference_error := marshal_reference_enter(
			builder, value.data, .Any, value.id,
		)
		if reference_error != nil {
			return {}, reference_error
		}
		defer marshal_reference_leave(builder, entered)
		return marshal_root_table(builder, unwrapped)
	case runtime.Type_Info_Struct:
		if .raw_union in metadata.flags {
			return {}, marshal_data_error(builder, .Unsupported_Type, value.id)
		}
		return marshal_struct_table(builder, value)
	case runtime.Type_Info_Map:
		return marshal_map_table(builder, value)
	}
	return {}, marshal_data_error(builder, .Invalid_Root_Shape, value.id)
}

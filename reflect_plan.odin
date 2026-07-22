package toml

import "base:runtime"
import "core:reflect"
import "core:unicode/utf8"
import temporal "vendor/temporal"

@(private)
marshal_integer_value :: proc(
	builder: ^Marshal_Builder,
	value: any,
) -> (Integer, Marshal_Error) {
	info := reflect.type_info_base(type_info_of(value.id))
	integer_info, ok := info.variant.(runtime.Type_Info_Integer)
	if !ok {
		return 0, marshal_data_error(builder, .Unsupported_Type, value.id)
	}
	core := reflect.any_core(value)
	if integer_info.signed {
		if info.size <= size_of(i64) {
			converted, valid := reflect.as_i64(core)
			if valid {
				return Integer(converted), nil
			}
		} else if info.size == size_of(i128) {
			wide: i128
			valid := true
			switch item in core {
			case i128:   wide = item
			case i128le: wide = i128(item)
			case i128be: wide = i128(item)
			case: valid = false
			}
			if valid && i128(min(i64)) <= wide && wide <= i128(max(i64)) {
				return Integer(wide), nil
			}
		}
	} else {
		if info.size <= size_of(u64) {
			converted, valid := reflect.as_u64(core)
			if valid && converted <= u64(max(i64)) {
				return Integer(converted), nil
			}
		} else if info.size == size_of(u128) {
			wide: u128
			valid := true
			switch item in core {
			case u128:   wide = item
			case u128le: wide = u128(item)
			case u128be: wide = u128(item)
			case: valid = false
			}
			if valid && wide <= u128(max(i64)) {
				return Integer(wide), nil
			}
		}
	}
	return 0, marshal_data_error(builder, .Integer_Out_Of_Range, value.id)
}

@(private)
marshal_float_value :: proc(
	builder: ^Marshal_Builder,
	value: any,
) -> (Float, Marshal_Error) {
	info := reflect.type_info_base(type_info_of(value.id))
	if _, ok := info.variant.(runtime.Type_Info_Float); !ok ||
	   (info.size != size_of(f16) && info.size != size_of(f32) && info.size != size_of(f64)) {
		return 0, marshal_data_error(builder, .Unsupported_Type, value.id)
	}
	core := reflect.any_core(value)
	converted: f64
	valid := true
	switch item in core {
	case f16:   converted = f64(item)
	case f32:   converted = f64(item)
	case f64:   converted = item
	case f32le: converted = f64(item)
	case f64le: converted = f64(item)
	case f32be: converted = f64(item)
	case f64be: converted = f64(item)
	case: valid = false
	}
	if !valid {
		return 0, marshal_data_error(builder, .Unsupported_Type, value.id)
	}
	return Float(converted), nil
}

@(private)
marshal_is_temporal_type :: proc(id: typeid) -> bool {
	return id == typeid_of(temporal.Offset_Date_Time) ||
	       id == typeid_of(temporal.Local_Date_Time) ||
	       id == typeid_of(temporal.Local_Date) ||
	       id == typeid_of(temporal.Local_Time)
}

@(private)
marshal_is_semantic_binding_type :: proc(id: typeid) -> bool {
	return id == typeid_of(Document) ||
	       id == typeid_of(Table) ||
	       id == typeid_of(Value)
}

@(private)
marshal_temporal_value :: proc(
	builder: ^Marshal_Builder,
	value: any,
) -> (Value, Marshal_Error, bool) {
	temporal_error: temporal.Error
	if value.id == typeid_of(temporal.Offset_Date_Time) {
		item := (^temporal.Offset_Date_Time)(value.data)^
		temporal_error = temporal.validate(item)
		if temporal_error != .None {
			zero_type: typeid
			return {}, marshal_data_error_detail(builder, .Invalid_Temporal, value.id, zero_type, temporal_error, 0, 0), true
		}
		return Value(item), nil, true
	}
	if value.id == typeid_of(temporal.Local_Date_Time) {
		item := (^temporal.Local_Date_Time)(value.data)^
		temporal_error = temporal.validate(item)
		if temporal_error != .None {
			zero_type: typeid
			return {}, marshal_data_error_detail(builder, .Invalid_Temporal, value.id, zero_type, temporal_error, 0, 0), true
		}
		return Value(item), nil, true
	}
	if value.id == typeid_of(temporal.Local_Date) {
		item := (^temporal.Local_Date)(value.data)^
		temporal_error = temporal.validate(item)
		if temporal_error != .None {
			zero_type: typeid
			return {}, marshal_data_error_detail(builder, .Invalid_Temporal, value.id, zero_type, temporal_error, 0, 0), true
		}
		return Value(item), nil, true
	}
	if value.id == typeid_of(temporal.Local_Time) {
		item := (^temporal.Local_Time)(value.data)^
		temporal_error = temporal.validate(item)
		if temporal_error != .None {
			zero_type: typeid
			return {}, marshal_data_error_detail(builder, .Invalid_Temporal, value.id, zero_type, temporal_error, 0, 0), true
		}
		return Value(item), nil, true
	}
	return {}, nil, false
}

@(private)
Marshal_Field_Tag :: struct {
	name:       string,
	ignore:     bool,
	omit_empty: bool,
}

@(private)
marshal_parse_field_tag :: proc(
	builder: ^Marshal_Builder,
	field: reflect.Struct_Field,
) -> (Marshal_Field_Tag, Marshal_Error) {
	result := Marshal_Field_Tag{name = field.name}
	raw := string(field.tag)
	toml_value := ""
	toml_count := 0
	for offset := 0; offset < len(raw); {
		for offset < len(raw) && raw[offset] == ' ' {
			offset += 1
		}
		if offset == len(raw) {
			break
		}
		name_start := offset
		for offset < len(raw) {
			character := raw[offset]
			if character == ':' || character == '"' ||
			   character < ' ' || (0x7f <= character && character <= 0x9f) {
				break
			}
			offset += 1
		}
		if offset == name_start || offset+1 >= len(raw) ||
		   raw[offset] != ':' || raw[offset+1] != '"' {
			return {}, marshal_data_error(builder, .Malformed_Tag, field.type.id)
		}
		name := raw[name_start:offset]
		offset += 2
		value_start := offset
		closed := false
		for offset < len(raw) {
			if raw[offset] == '"' {
				closed = true
				break
			}
			if raw[offset] == '\\' {
				offset += 1
				if offset >= len(raw) {
					break
				}
			}
			offset += 1
		}
		if !closed {
			return {}, marshal_data_error(builder, .Malformed_Tag, field.type.id)
		}
		if name == "toml" {
			toml_count += 1
			if toml_count > 1 {
				return {}, marshal_data_error(builder, .Malformed_Tag, field.type.id)
			}
			toml_value = raw[value_start:offset]
		}
		offset += 1
	}
	if toml_count == 0 || toml_value == "" {
		return result, nil
	}
	if toml_value == "-" {
		result.ignore = true
		return result, nil
	}
	comma := -1
	for character, index in toml_value {
		if character == ',' {
			if comma >= 0 {
				return {}, marshal_data_error(builder, .Malformed_Tag, field.type.id)
			}
			comma = index
		}
	}
	name := toml_value
	if comma >= 0 {
		name = toml_value[:comma]
		if name == "-" {
			return {}, marshal_data_error(builder, .Malformed_Tag, field.type.id)
		}
		option := toml_value[comma+1:]
		if option != "omitempty" {
			return {}, marshal_data_error(builder, .Malformed_Tag, field.type.id)
		}
		result.omit_empty = true
	}
	if name != "" {
		result.name = name
	}
	if !utf8.valid_string(result.name) {
		return {}, marshal_data_error(builder, .Malformed_Tag, field.type.id)
	}
	return result, nil
}

@(private)
marshal_is_anonymous_using :: proc(field: reflect.Struct_Field) -> bool {
	return field.is_using && field.name == "_"
}

@(private)
marshal_projected_field_count :: proc(
	builder: ^Marshal_Builder,
	source_type: typeid,
) -> (count: int, err: Marshal_Error) {
	info := reflect.type_info_base(type_info_of(source_type))
	metadata, ok := info.variant.(runtime.Type_Info_Struct)
	if !ok || .raw_union in metadata.flags {
		return 0, marshal_data_error(builder, .Unsupported_Type, source_type)
	}
	for field in reflect.struct_fields_zipped(source_type) {
		tag, tag_error := marshal_parse_field_tag(builder, field)
		if tag_error != nil {
			return 0, tag_error
		}
		if tag.ignore {
			continue
		}
		if marshal_is_anonymous_using(field) {
			if tag.omit_empty || tag.name != field.name {
				return 0, marshal_data_error(builder, .Malformed_Tag, field.type.id)
			}
			child_count, child_error := marshal_projected_field_count(builder, field.type.id)
			if child_error != nil {
				return 0, child_error
			}
			if child_count > max(int)-count {
				return 0, marshal_limit_error(builder, .Size_Overflow)
			}
			count += child_count
			continue
		}
		if count == max(int) {
			return 0, marshal_limit_error(builder, .Size_Overflow)
		}
		count += 1
	}
	return
}

@(private)
Marshal_Projected_Field :: struct {
	tag:         Marshal_Field_Tag,
	source_type: typeid,
	offset:      uintptr,
}

@(private)
Marshal_Struct_Plan :: struct {
	fields: [dynamic]Marshal_Projected_Field,
}

@(private)
marshal_struct_plan_destroy :: proc(
	builder: ^Marshal_Builder,
	plan: ^Marshal_Struct_Plan,
) {
	if plan == nil {
		return
	}
	release_owned_memory(
		&builder.gate,
		raw_data(plan.fields),
		cap(plan.fields)*size_of(Marshal_Projected_Field),
		builder.loc,
	)
	plan^ = {}
}

@(private)
marshal_projected_fields_fill :: proc(
	builder: ^Marshal_Builder,
	source_type: typeid,
	base_offset: uintptr,
	fields: []Marshal_Projected_Field,
	cursor: ^int,
) -> Marshal_Error {
	for field in reflect.struct_fields_zipped(source_type) {
		tag, tag_error := marshal_parse_field_tag(builder, field)
		if tag_error != nil {
			return tag_error
		}
		if tag.ignore {
			continue
		}
		if marshal_is_anonymous_using(field) {
			if err := marshal_projected_fields_fill(
				builder,
				field.type.id,
				base_offset+field.offset,
				fields,
				cursor,
			); err != nil {
				return err
			}
			continue
		}
		assert(cursor^ < len(fields))
		fields[cursor^] = {
			tag = tag,
			source_type = field.type.id,
			offset = base_offset+field.offset,
		}
		cursor^ += 1
	}
	return nil
}

@(private)
marshal_struct_plan_build :: proc(
	builder: ^Marshal_Builder,
	source_type: typeid,
) -> (plan: Marshal_Struct_Plan, err: Marshal_Error) {
	count, count_error := marshal_projected_field_count(builder, source_type)
	if count_error != nil {
		return {}, count_error
	}
	raw, storage_error := make_owned_dynamic_array_storage(
		count,
		size_of(Marshal_Projected_Field),
		builder.allocator,
		builder.loc,
	)
	if storage_error != nil {
		if allocator_error, ok := storage_error.(runtime.Allocator_Error); ok {
			return {}, allocator_error
		}
		return {}, marshal_limit_error(builder, .Size_Overflow)
	}
	plan.fields = transmute([dynamic]Marshal_Projected_Field)raw
	cursor := 0
	if fill_error := marshal_projected_fields_fill(
		builder,
		source_type,
		0,
		plan.fields[:],
		&cursor,
	); fill_error != nil {
		marshal_struct_plan_destroy(builder, &plan)
		return {}, fill_error
	}
	assert(cursor == len(plan.fields))
	for current, index in plan.fields {
		for previous in plan.fields[:index] {
			if current.tag.name == previous.tag.name {
				err = marshal_data_error_detail(
					builder,
					.Effective_Field_Name_Collision,
					current.source_type,
					previous.source_type,
					.None,
					0,
					0,
				)
				marshal_struct_plan_destroy(builder, &plan)
				return {}, err
			}
		}
	}
	return
}

@(private)
marshal_projected_field_value_by_name :: proc(
	builder: ^Marshal_Builder,
	struct_value: any,
	name: string,
) -> (stable_name: string, value: any, ok: bool) {
	for field in reflect.struct_fields_zipped(struct_value.id) {
		tag, tag_error := marshal_parse_field_tag(builder, field)
		if tag_error != nil || tag.ignore {
			continue
		}
		field_value := any{
			rawptr(uintptr(struct_value.data)+field.offset),
			field.type.id,
		}
		if marshal_is_anonymous_using(field) {
			if child_name, child, found := marshal_projected_field_value_by_name(
				builder,
				field_value,
				name,
			); found {
				return child_name, child, true
			}
			continue
		}
		if tag.name == name {
			return tag.name, field_value, true
		}
	}
	return "", nil, false
}

@(private)
marshal_rebase_projected_suffix :: proc(
	builder: ^Marshal_Builder,
	current: any,
	skipped_count: int,
	temporary: []Encode_Diagnostic_Path_Segment,
	stable: []Encode_Diagnostic_Path_Segment,
) -> bool {
	if skipped_count == 0 {
		value := current
		for segment, index in temporary {
			name, is_name := segment.(string)
			if !is_name {
				return false
			}
			stable_name, field_value, found := marshal_projected_field_value_by_name(
				builder,
				value,
				name,
			)
			if !found {
				return false
			}
			stable[index] = stable_name
			value = field_value
		}
		return true
	}
	return marshal_rebase_projected_suffix_through_fields(
		builder,
		current,
		skipped_count,
		temporary,
		stable,
	)
}

@(private)
marshal_rebase_projected_suffix_through_fields :: proc(
	builder: ^Marshal_Builder,
	struct_value: any,
	skipped_count: int,
	temporary: []Encode_Diagnostic_Path_Segment,
	stable: []Encode_Diagnostic_Path_Segment,
) -> bool {
	for field in reflect.struct_fields_zipped(struct_value.id) {
		tag, tag_error := marshal_parse_field_tag(builder, field)
		if tag_error != nil || tag.ignore {
			continue
		}
		field_value := any{
			rawptr(uintptr(struct_value.data)+field.offset),
			field.type.id,
		}
		if marshal_is_anonymous_using(field) {
			if marshal_rebase_projected_suffix_through_fields(
				builder,
				field_value,
				skipped_count,
				temporary,
				stable,
			) {
				return true
			}
			continue
		}
		if marshal_rebase_projected_suffix(
			builder,
			field_value,
			skipped_count-1,
			temporary,
			stable,
		) {
			return true
		}
	}
	return false
}

@(private)
marshal_is_empty :: proc(value: any) -> bool {
	if value == nil {
		return true
	}
	info := reflect.type_info_base(type_info_of(value.id))
	#partial switch metadata in info.variant {
	case runtime.Type_Info_Boolean:
		item, ok := reflect.as_bool(value)
		return ok && !item
	case runtime.Type_Info_Integer:
		bytes := ([^]byte)(value.data)[:info.size]
		for item in bytes {
			if item != 0 {
				return false
			}
		}
		return true
	case runtime.Type_Info_Float:
		core := reflect.any_core(value)
		switch item in core {
		case f16: return item == 0
		case f32: return item == 0
		case f64: return item == 0
		case f32le: return item == 0
		case f64le: return item == 0
		case f32be: return item == 0
		case f64be: return item == 0
		}
		return false
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
		if metadata.no_nil || len(metadata.variants) != 1 {
			return false
		}
		if reflect.type_info_union_is_pure_maybe(metadata) {
			return (^rawptr)(value.data)^ == nil
		}
		return reflect.union_variant_typeid(value) == nil
	case runtime.Type_Info_Any:
		return (^any)(value.data)^ == nil
	}
	return false
}

@(private)
marshal_struct_table :: proc(
	builder: ^Marshal_Builder,
	value: any,
) -> (Table, Marshal_Error) {
	plan, plan_error := marshal_struct_plan_build(builder, value.id)
	if plan_error != nil {
		return {}, plan_error
	}
	defer marshal_struct_plan_destroy(builder, &plan)
	selected_count := 0
	for projected in plan.fields {
		field_value := any{
			rawptr(uintptr(value.data)+projected.offset),
			projected.source_type,
		}
		if projected.tag.omit_empty && marshal_is_empty(field_value) {
			continue
		}
		selected_count += 1
	}
	table, table_error := make_owned_table(selected_count, builder.allocator, builder.loc)
	if table_error != nil {
		if allocator_error, ok := table_error.(runtime.Allocator_Error); ok {
			return {}, allocator_error
		}
		return {}, marshal_limit_error(builder, .Size_Overflow)
	}
	output_index := 0
	for projected in plan.fields {
		field_value := any{
			rawptr(uintptr(value.data)+projected.offset),
			projected.source_type,
		}
		if projected.tag.omit_empty && marshal_is_empty(field_value) {
			continue
		}
		key, key_error := marshal_clone_text(
			builder,
			projected.tag.name,
			projected.source_type,
		)
		if key_error != nil {
			destroy_table_with_gate(&table, &builder.gate, builder.loc)
			return {}, key_error
		}
		table[output_index].key = key
		if path_error := marshal_push_path(builder, projected.tag.name); path_error != nil {
			destroy_table_with_gate(&table, &builder.gate, builder.loc)
			return {}, path_error
		}
		converted, value_error := marshal_reflected_value(builder, field_value)
		marshal_pop_path(builder)
		if value_error != nil {
			destroy_table_with_gate(&table, &builder.gate, builder.loc)
			return {}, value_error
		}
		table[output_index].value = converted
		output_index += 1
	}
	assert(output_index == len(table))
	return table, nil
}

@(private)
marshal_reflected_value :: proc(
	builder: ^Marshal_Builder,
	value: any,
) -> (Value, Marshal_Error) {
	if value == nil {
		zero_type: typeid
		return {}, marshal_data_error(builder, .Unsupported_Nil, zero_type)
	}
	if value.id == typeid_of(any) {
		return marshal_any_value(builder, value)
	}
	if codec_value, codec_error, handled := marshal_codec_value(builder, value); handled {
		return codec_value, codec_error
	}
	if temporal_value, temporal_error, handled := marshal_temporal_value(builder, value); handled {
		return temporal_value, temporal_error
	}
	if marshal_is_semantic_binding_type(value.id) {
		return {}, marshal_data_error(builder, .Unsupported_Type, value.id)
	}
	info := reflect.type_info_base(type_info_of(value.id))
	#partial switch _ in info.variant {
	case runtime.Type_Info_String:
		metadata := info.variant.(runtime.Type_Info_String)
		if metadata.is_cstring || metadata.encoding != .UTF_8 {
			return {}, marshal_data_error(builder, .Unsupported_Type, value.id)
		}
		text, valid := reflect.as_string(value)
		if !valid {
			return {}, marshal_data_error(builder, .Unsupported_Type, value.id)
		}
		cloned, err := marshal_clone_text(builder, text, value.id)
		if err != nil {
			return {}, err
		}
		return Value(String(cloned)), nil
	case runtime.Type_Info_Boolean:
		item, valid := reflect.as_bool(value)
		if !valid {
			return {}, marshal_data_error(builder, .Unsupported_Type, value.id)
		}
		return Value(Boolean(item)), nil
	case runtime.Type_Info_Integer:
		item, err := marshal_integer_value(builder, value)
		return Value(item), err
	case runtime.Type_Info_Float:
		item, err := marshal_float_value(builder, value)
		return Value(item), err
	case runtime.Type_Info_Array,
	     runtime.Type_Info_Enumerated_Array,
	     runtime.Type_Info_Slice,
	     runtime.Type_Info_Dynamic_Array:
		return marshal_sequence_value(builder, value)
	case runtime.Type_Info_Map:
		table, err := marshal_map_table(builder, value)
		return Value(table), err
	case runtime.Type_Info_Pointer:
		return marshal_pointer_value(builder, value)
	case runtime.Type_Info_Union:
		return marshal_union_value(builder, value)
	case runtime.Type_Info_Any:
		return marshal_any_value(builder, value)
	case runtime.Type_Info_Struct:
		table, err := marshal_struct_table(builder, value)
		return Value(table), err
	}
	return {}, marshal_data_error(builder, .Unsupported_Type, value.id)
}

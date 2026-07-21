package toml

import "base:runtime"
import "core:mem"
import "core:reflect"
import "core:unicode/utf8"
import temporal "temporal"

@(private)
SEMANTIC_MAX_DEPTH :: 256

@(private)
Semantic_Data_Error :: enum u8 {
	Invalid_Document,
	Invalid_Table,
	Invalid_Value_State,
	Invalid_Container,
	Uninitialized_Container,
	Invalid_Key_Text,
	Invalid_Value_Text,
	Duplicate_Key,
	Invalid_Temporal,
	Cycle,
	Ownership_Alias,
	Allocator_Mismatch,
}

@(private)
Semantic_Diagnostic_Detail :: union #no_nil {
	Semantic_Data_Error,
	Mutation_Limit_Error,
}

@(private)
Semantic_Diagnostic :: struct {
	detail:         Semantic_Diagnostic_Detail,
	temporal_error: temporal.Error,
	path:           Encode_Diagnostic_Path,
}

@(private)
Semantic_Validation_Error :: union {
	Semantic_Diagnostic,
	runtime.Allocator_Error,
}

@(private)
Owned_Region_Kind :: enum u8 {
	String,
	Container,
}

@(private)
Owned_Region :: struct {
	start:  uintptr,
	size:   int,
	kind:   Owned_Region_Kind,
	active: bool,
}

@(private)
Semantic_Validation_State :: struct {
	allocator:          mem.Allocator,
	cleanup_gate:       Allocator_Release_Gate,
	regions:            [dynamic]Owned_Region,
	required_allocator: mem.Allocator,
	require_allocator:  bool,
	path:                [SEMANTIC_MAX_DEPTH + 1]Encode_Diagnostic_Path_Segment,
	path_count:          int,
	max_depth:           int,
}

@(private)
semantic_validation_state_init :: proc(
	allocator: mem.Allocator,
	required_allocator: mem.Allocator = {},
	require_allocator := false,
	loc := #caller_location,
	max_depth := SEMANTIC_MAX_DEPTH,
) -> (state: Semantic_Validation_State, err: runtime.Allocator_Error) {
	state.allocator = allocator
	state.required_allocator = required_allocator
	state.require_allocator = require_allocator
	state.max_depth = max_depth
	state.cleanup_gate, err = allocator_release_gate_init(allocator, loc)
	return
}

@(private)
semantic_validation_state_destroy :: proc(
	state: ^Semantic_Validation_State,
	loc := #caller_location,
) {
	if state == nil {
		return
	}
	release_owned_memory(
		&state.cleanup_gate,
		raw_data(state.regions),
		cap(state.regions)*size_of(Owned_Region),
		loc,
	)
	state^ = {}
}

@(private)
semantic_validation_state_reset :: proc(
	state: ^Semantic_Validation_State,
	required_allocator: mem.Allocator = {},
	require_allocator := false,
) {
	raw := transmute(runtime.Raw_Dynamic_Array)state.regions
	raw.len = 0
	state.regions = transmute([dynamic]Owned_Region)raw
	state.required_allocator = required_allocator
	state.require_allocator = require_allocator
	state.path_count = 0
}

@(private)
semantic_path_snapshot :: proc(state: ^Semantic_Validation_State) -> Encode_Diagnostic_Path {
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
	suffix_count := len(result.segments) - prefix_count
	result.segment_count = u8(len(result.segments))
	result.prefix_count = u8(prefix_count)
	result.omitted_segment_count = u16(count - len(result.segments))
	result.truncated = true
	copy(result.segments[:prefix_count], state.path[:prefix_count])
	copy(
		result.segments[prefix_count:],
		state.path[count - suffix_count:count],
	)
	return result
}

@(private)
semantic_diagnostic :: proc(
	state: ^Semantic_Validation_State,
	detail: Semantic_Diagnostic_Detail,
	temporal_error := temporal.Error.None,
) -> Semantic_Validation_Error {
	return Semantic_Diagnostic{
		detail = detail,
		temporal_error = temporal_error,
		path = semantic_path_snapshot(state),
	}
}

@(private)
semantic_push_path :: proc(
	state: ^Semantic_Validation_State,
	segment: Encode_Diagnostic_Path_Segment,
) -> Semantic_Validation_Error {
	if state.path_count >= state.max_depth {
		state.path[state.path_count] = segment
		state.path_count += 1
		err := semantic_diagnostic(state, Mutation_Limit_Error.Maximum_Depth_Exceeded)
		state.path_count -= 1
		state.path[state.path_count] = {}
		return err
	}
	state.path[state.path_count] = segment
	state.path_count += 1
	return nil
}

@(private)
semantic_pop_path :: proc(state: ^Semantic_Validation_State) {
	assert(state.path_count > 0)
	state.path_count -= 1
	state.path[state.path_count] = {}
}

@(private)
regions_overlap :: proc(a_start: uintptr, a_size: int, b_start: uintptr, b_size: int) -> bool {
	assert(a_size > 0 && b_size > 0)
	if a_start <= b_start {
		return b_start - a_start < uintptr(a_size)
	}
	return a_start - b_start < uintptr(b_size)
}

@(private)
semantic_append_region :: proc(
	state: ^Semantic_Validation_State,
	region: Owned_Region,
	loc: runtime.Source_Code_Location,
) -> Semantic_Validation_Error {
	old_length := len(state.regions)
	if old_length < cap(state.regions) {
		raw := transmute(runtime.Raw_Dynamic_Array)state.regions
		raw.len = old_length + 1
		state.regions = transmute([dynamic]Owned_Region)raw
		state.regions[old_length] = region
		return nil
	}

	new_capacity := 8
	if old_length > 0 {
		if old_length > max(int)/2 {
			return semantic_diagnostic(state, Mutation_Limit_Error.Size_Overflow)
		}
		new_capacity = old_length*2
	}
	if new_capacity > max(int)/size_of(Owned_Region) {
		return semantic_diagnostic(state, Mutation_Limit_Error.Size_Overflow)
	}
	new_raw, err := make_owned_dynamic_array_storage(
		new_capacity,
		size_of(Owned_Region),
		state.allocator,
		loc,
	)
	if err != nil {
		if allocator_error, ok := err.(runtime.Allocator_Error); ok {
			return allocator_error
		}
		return semantic_diagnostic(state, Mutation_Limit_Error.Size_Overflow)
	}
	new_raw.len = old_length + 1
	new_regions := transmute([dynamic]Owned_Region)new_raw
	if old_length > 0 {
		mem.copy_non_overlapping(
			raw_data(new_regions),
			raw_data(state.regions),
			old_length*size_of(Owned_Region),
		)
	}
	new_regions[old_length] = region
	release_owned_memory(
		&state.cleanup_gate,
		raw_data(state.regions),
		cap(state.regions)*size_of(Owned_Region),
		loc,
	)
	state.regions = new_regions
	return nil
}

@(private)
semantic_register_region :: proc(
	state: ^Semantic_Validation_State,
	memory: rawptr,
	size: int,
	kind: Owned_Region_Kind,
	active := false,
	loc := #caller_location,
) -> (index: int, err: Semantic_Validation_Error) {
	if size == 0 {
		return -1, nil
	}
	if memory == nil || size < 0 {
		return -1, semantic_diagnostic(state, Semantic_Data_Error.Invalid_Container)
	}
	start := uintptr(memory)
	for existing in state.regions {
		if !regions_overlap(start, size, existing.start, existing.size) {
			continue
		}
		if kind == .Container && existing.kind == .Container && existing.active &&
		   start == existing.start && size == existing.size {
			return -1, semantic_diagnostic(state, Semantic_Data_Error.Cycle)
		}
		return -1, semantic_diagnostic(state, Semantic_Data_Error.Ownership_Alias)
	}
	append_error := semantic_append_region(
		state,
		Owned_Region{start = start, size = size, kind = kind, active = active},
		loc,
	)
	if append_error != nil {
		return -1, append_error
	}
	return len(state.regions) - 1, nil
}

@(private)
semantic_validate_allocator :: proc(
	state: ^Semantic_Validation_State,
	allocator: mem.Allocator,
) -> Semantic_Validation_Error {
	if allocator.procedure == nil {
		return semantic_diagnostic(state, Semantic_Data_Error.Uninitialized_Container)
	}
	if !state.require_allocator {
		state.required_allocator = allocator
		state.require_allocator = true
		return nil
	}
	if !allocator_equal(allocator, state.required_allocator) {
		return semantic_diagnostic(state, Semantic_Data_Error.Allocator_Mismatch)
	}
	return nil
}

@(private)
semantic_validate_container_raw :: proc(
	state: ^Semantic_Validation_State,
	raw: runtime.Raw_Dynamic_Array,
	element_size: int,
	root_table := false,
	loc := #caller_location,
) -> (region_index: int, err: Semantic_Validation_Error) {
	invalid_kind := Semantic_Data_Error.Invalid_Container
	if root_table {
		invalid_kind = .Invalid_Table
	}
	if raw.len < 0 || raw.cap < raw.len || raw.cap < 0 ||
	   (raw.cap == 0 && raw.data != nil) || (raw.cap > 0 && raw.data == nil) {
		return -1, semantic_diagnostic(state, invalid_kind)
	}
	if allocator_error := semantic_validate_allocator(state, raw.allocator); allocator_error != nil {
		return -1, allocator_error
	}
	if raw.cap > max(int)/element_size {
		return -1, semantic_diagnostic(state, Mutation_Limit_Error.Size_Overflow)
	}
	// An empty root has no reachable child that could alias its retained
	// storage. Avoid allocating region scratch so every empty document keeps
	// the canonical encoder's zero-allocation result contract.
	if root_table && raw.len == 0 {
		return -1, nil
	}
	return semantic_register_region(
		state,
		raw.data,
		raw.cap*element_size,
		.Container,
		true,
		loc,
	)
}

@(private)
semantic_validate_text :: proc(
	state: ^Semantic_Validation_State,
	text: string,
	kind: Semantic_Data_Error,
	loc := #caller_location,
) -> Semantic_Validation_Error {
	if !utf8.valid_string(text) {
		return semantic_diagnostic(state, kind)
	}
	if len(text) == 0 {
		return nil
	}
	_, err := semantic_register_region(state, raw_data(text), len(text), .String, loc = loc)
	return err
}

@(private)
semantic_validate_value :: proc(
	state: ^Semantic_Validation_State,
	value: ^Value,
	loc := #caller_location,
) -> Semantic_Validation_Error {
	if value == nil {
		return semantic_diagnostic(state, Semantic_Data_Error.Invalid_Value_State)
	}
	tag := reflect.get_union_variant_raw_tag(value^)
	if tag < 0 || tag >= 10 {
		return semantic_diagnostic(state, Semantic_Data_Error.Invalid_Value_State)
	}

	switch item in value^ {
	case String:
		return semantic_validate_text(state, item, .Invalid_Value_Text, loc)
	case Integer, Float, Boolean:
		return nil
	case temporal.Offset_Date_Time:
		if temporal_error := temporal.validate(item); temporal_error != .None {
			return semantic_diagnostic(state, Semantic_Data_Error.Invalid_Temporal, temporal_error)
		}
		return nil
	case temporal.Local_Date_Time:
		if temporal_error := temporal.validate(item); temporal_error != .None {
			return semantic_diagnostic(state, Semantic_Data_Error.Invalid_Temporal, temporal_error)
		}
		return nil
	case temporal.Local_Date:
		if temporal_error := temporal.validate(item); temporal_error != .None {
			return semantic_diagnostic(state, Semantic_Data_Error.Invalid_Temporal, temporal_error)
		}
		return nil
	case temporal.Local_Time:
		if temporal_error := temporal.validate(item); temporal_error != .None {
			return semantic_diagnostic(state, Semantic_Data_Error.Invalid_Temporal, temporal_error)
		}
		return nil
	case Array:
		return semantic_validate_array(state, item, loc)
	case Table:
		return semantic_validate_table(state, item, false, loc)
	}
	unreachable()
}

@(private)
semantic_validate_array :: proc(
	state: ^Semantic_Validation_State,
	array: Array,
	loc: runtime.Source_Code_Location,
) -> Semantic_Validation_Error {
	raw := transmute(runtime.Raw_Dynamic_Array)array
	region_index, err := semantic_validate_container_raw(state, raw, size_of(Value), loc = loc)
	if err != nil {
		return err
	}
	defer if region_index >= 0 {
		state.regions[region_index].active = false
	}
	for &child, index in array {
		if path_error := semantic_push_path(state, Path_Index(index)); path_error != nil {
			return path_error
		}
		child_error := semantic_validate_value(state, &child, loc)
		semantic_pop_path(state)
		if child_error != nil {
			return child_error
		}
	}
	return nil
}

@(private)
semantic_validate_table :: proc(
	state: ^Semantic_Validation_State,
	table: Table,
	root_table: bool,
	loc: runtime.Source_Code_Location,
) -> Semantic_Validation_Error {
	raw := transmute(runtime.Raw_Dynamic_Array)table
	region_index, err := semantic_validate_container_raw(
		state,
		raw,
		size_of(Entry),
		root_table,
		loc,
	)
	if err != nil {
		return err
	}
	defer if region_index >= 0 {
		state.regions[region_index].active = false
	}
	for &entry, index in table {
		if path_error := semantic_push_path(state, entry.key); path_error != nil {
			return path_error
		}
		if !utf8.valid_string(entry.key) {
			err = semantic_diagnostic(state, Semantic_Data_Error.Invalid_Key_Text)
			semantic_pop_path(state)
			return err
		}
		for previous in table[:index] {
			if previous.key == entry.key {
				err = semantic_diagnostic(state, Semantic_Data_Error.Duplicate_Key)
				semantic_pop_path(state)
				return err
			}
		}
		if key_error := semantic_validate_text(state, entry.key, .Invalid_Key_Text, loc); key_error != nil {
			semantic_pop_path(state)
			return key_error
		}
		value_error := semantic_validate_value(state, &entry.value, loc)
		semantic_pop_path(state)
		if value_error != nil {
			return value_error
		}
	}
	return nil
}

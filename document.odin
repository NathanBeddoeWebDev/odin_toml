package toml

import "base:runtime"
import "core:mem"
import temporal "temporal"

@(private)
clone_configuration_error :: proc(kind: Clone_Configuration_Error) -> Clone_Error {
	return kind
}

@(private)
clone_data_error :: proc(kind: Clone_Data_Error_Kind) -> Clone_Error {
	return Clone_Diagnostic{detail = Clone_Diagnostic_Detail(kind)}
}

@(private)
clone_limit_error :: proc(kind: Clone_Limit_Error) -> Clone_Error {
	return Clone_Diagnostic{detail = Clone_Diagnostic_Detail(kind)}
}

@(private)
allocator_equal :: proc(a, b: mem.Allocator) -> bool {
	return a.procedure == b.procedure && a.data == b.data
}

@(private)
clone_owned_string :: proc(
	text: string,
	allocator: mem.Allocator,
	loc: runtime.Source_Code_Location,
) -> (string, Clone_Error) {
	if len(text) == 0 {
		return "", nil
	}
	memory, err := allocator_allocate(len(text), allocator, false, loc)
	if err != nil {
		return "", err
	}
	if memory == nil {
		return "", runtime.Allocator_Error.Out_Of_Memory
	}
	mem.copy_non_overlapping(memory, raw_data(text), len(text))
	return string(mem.byte_slice(memory, len(text))), nil
}

@(private)
make_owned_dynamic_array_storage :: proc(
	count, element_size: int,
	allocator: mem.Allocator,
	loc: runtime.Source_Code_Location,
) -> (runtime.Raw_Dynamic_Array, Clone_Error) {
	if count < 0 || count > max(int)/element_size {
		return {}, clone_limit_error(.Size_Overflow)
	}
	memory: rawptr
	if count > 0 {
		allocation_error: runtime.Allocator_Error
		memory, allocation_error = allocator_allocate(
			count*element_size,
			allocator,
			true,
			loc,
		)
		if allocation_error != nil {
			return {}, allocation_error
		}
		if memory == nil {
			return {}, runtime.Allocator_Error.Out_Of_Memory
		}
	}
	return runtime.Raw_Dynamic_Array{
		data = memory,
		len = count,
		cap = count,
		allocator = allocator,
	}, nil
}

@(private)
make_owned_array :: proc(
	count: int,
	allocator: mem.Allocator,
	loc: runtime.Source_Code_Location,
) -> (Array, Clone_Error) {
	raw, err := make_owned_dynamic_array_storage(count, size_of(Value), allocator, loc)
	return transmute(Array)raw, err
}

@(private)
make_owned_table :: proc(
	count: int,
	allocator: mem.Allocator,
	loc: runtime.Source_Code_Location,
) -> (Table, Clone_Error) {
	raw, err := make_owned_dynamic_array_storage(count, size_of(Entry), allocator, loc)
	return transmute(Table)raw, err
}

@(private)
release_owned_memory :: proc(
	gate: ^Allocator_Release_Gate,
	memory: rawptr,
	size: int,
	loc: runtime.Source_Code_Location,
) {
	if memory == nil {
		return
	}
	err := allocator_release_gate_release(gate, memory, size, loc)
	assert(err == nil, "semantic owner allocator violated its destruction contract")
}

@(private)
destroy_value_with_gate :: proc(
	value: ^Value,
	gate: ^Allocator_Release_Gate,
	loc: runtime.Source_Code_Location,
) {
	if value == nil {
		return
	}

	switch item in value^ {
	case String:
		release_owned_memory(gate, raw_data(item), len(item), loc)
	case Array:
		for &child in item {
			destroy_value_with_gate(&child, gate, loc)
		}
		release_owned_memory(gate, raw_data(item), cap(item)*size_of(Value), loc)
	case Table:
		for &entry in item {
			release_owned_memory(gate, raw_data(entry.key), len(entry.key), loc)
			entry.key = ""
			destroy_value_with_gate(&entry.value, gate, loc)
		}
		release_owned_memory(gate, raw_data(item), cap(item)*size_of(Entry), loc)
	case Integer, Float, Boolean,
	     temporal.Offset_Date_Time, temporal.Local_Date_Time,
	     temporal.Local_Date, temporal.Local_Time:
	}
	value^ = {}
}

@(private)
destroy_table_with_gate :: proc(
	table: ^Table,
	gate: ^Allocator_Release_Gate,
	loc: runtime.Source_Code_Location,
) {
	if table == nil {
		return
	}
	for &entry in table {
		release_owned_memory(gate, raw_data(entry.key), len(entry.key), loc)
		entry.key = ""
		destroy_value_with_gate(&entry.value, gate, loc)
	}
	release_owned_memory(gate, raw_data(table^), cap(table^)*size_of(Entry), loc)
	table^ = {}
}

@(private)
clone_value_with_gate :: proc(
	source: ^Value,
	allocator: mem.Allocator,
	cleanup_gate: ^Allocator_Release_Gate,
	loc: runtime.Source_Code_Location,
) -> (result: Value, err: Clone_Error) {
	if source == nil {
		return {}, clone_data_error(.Invalid_Value_State)
	}

	switch item in source^ {
	case String:
		cloned: string
		cloned, err = clone_owned_string(item, allocator, loc)
		if err != nil {
			return {}, err
		}
		return Value(String(cloned)), nil
	case Integer:
		return Value(item), nil
	case Float:
		return Value(item), nil
	case Boolean:
		return Value(item), nil
	case temporal.Offset_Date_Time:
		return Value(item), nil
	case temporal.Local_Date_Time:
		return Value(item), nil
	case temporal.Local_Date:
		return Value(item), nil
	case temporal.Local_Time:
		return Value(item), nil
	case Array:
		if item.allocator.procedure == nil {
			return {}, clone_data_error(.Invalid_Container)
		}
		cloned: Array
		cloned, err = make_owned_array(len(item), allocator, loc)
		if err != nil {
			return {}, err
		}
		for &child, index in item {
			cloned[index], err = clone_value_with_gate(&child, allocator, cleanup_gate, loc)
			if err != nil {
				result = Value(cloned)
				destroy_value_with_gate(&result, cleanup_gate, loc)
				return {}, err
			}
		}
		return Value(cloned), nil
	case Table:
		if item.allocator.procedure == nil {
			return {}, clone_data_error(.Invalid_Container)
		}
		cloned: Table
		cloned, err = clone_table_with_gate(item, allocator, cleanup_gate, loc)
		if err != nil {
			return {}, err
		}
		return Value(cloned), nil
	}
	unreachable()
}

@(private)
clone_table_with_gate :: proc(
	source: Table,
	allocator: mem.Allocator,
	cleanup_gate: ^Allocator_Release_Gate,
	loc: runtime.Source_Code_Location,
) -> (result: Table, err: Clone_Error) {
	if source.allocator.procedure == nil {
		return {}, clone_data_error(.Invalid_Container)
	}
	result, err = make_owned_table(len(source), allocator, loc)
	if err != nil {
		return {}, err
	}
	for &entry, index in source {
		result[index].key, err = clone_owned_string(entry.key, allocator, loc)
		if err != nil {
			destroy_table_with_gate(&result, cleanup_gate, loc)
			return {}, err
		}
		result[index].value, err = clone_value_with_gate(
			&entry.value,
			allocator,
			cleanup_gate,
			loc,
		)
		if err != nil {
			destroy_table_with_gate(&result, cleanup_gate, loc)
			return {}, err
		}
	}
	return result, nil
}

@(require_results)
clone_document :: proc(
	doc: ^Document,
	allocator := context.allocator,
	loc := #caller_location,
) -> (Document, Clone_Error) {
	if allocator.procedure == nil {
		return {}, clone_configuration_error(.Invalid_Allocator)
	}
	if doc == nil || doc.allocator.procedure == nil ||
	   doc.root.allocator.procedure == nil ||
	   !allocator_equal(doc.root.allocator, doc.allocator) {
		return {}, clone_data_error(.Invalid_Document)
	}

	cleanup_gate, gate_error := allocator_release_gate_init(allocator, loc)
	if gate_error != nil {
		return {}, gate_error
	}
	root, err := clone_table_with_gate(doc.root, allocator, &cleanup_gate, loc)
	if err != nil {
		return {}, err
	}
	return Document{root = root, allocator = allocator}, nil
}

destroy_document :: proc(doc: ^Document, loc := #caller_location) {
	if doc == nil || (doc.allocator.procedure == nil && doc.root.allocator.procedure == nil) {
		return
	}
	owner := doc^
	doc^ = {}
	gate, gate_error := allocator_release_gate_init(owner.allocator, loc)
	assert(gate_error == nil, "semantic owner allocator rejected destruction setup")
	destroy_table_with_gate(&owner.root, &gate, loc)
	owner = {}
}

@(require_results)
clone_value :: proc(
	value: ^Value,
	allocator := context.allocator,
	loc := #caller_location,
) -> (Value, Clone_Error) {
	if allocator.procedure == nil {
		return {}, clone_configuration_error(.Invalid_Allocator)
	}
	if value == nil {
		return {}, clone_data_error(.Invalid_Value_State)
	}
	cleanup_gate, gate_error := allocator_release_gate_init(allocator, loc)
	if gate_error != nil {
		return {}, gate_error
	}
	return clone_value_with_gate(value, allocator, &cleanup_gate, loc)
}

destroy_value :: proc(
	value: ^Value,
	allocator: mem.Allocator,
	loc := #caller_location,
) {
	if value == nil {
		return
	}
	if text, ok := value^.(String); ok && len(text) == 0 {
		value^ = {}
		return
	}
	gate, gate_error := allocator_release_gate_init(allocator, loc)
	assert(gate_error == nil, "semantic owner allocator rejected destruction setup")
	destroy_value_with_gate(value, &gate, loc)
}

@(require_results)
get :: proc(table: ^Table, key: string) -> (^Value, bool) {
	if table == nil {
		return nil, false
	}
	for &entry in table {
		if entry.key == key {
			return &entry.value, true
		}
	}
	return nil, false
}

@(require_results)
set :: proc(
	table: ^Table,
	key: string,
	value: ^Value,
	loc := #caller_location,
) -> Mutation_Error {
	_, _, _, _ = table, key, value, loc
	unimplemented("semantic mutation is scheduled for implementation ticket 9")
}

@(require_results)
remove :: proc(table: ^Table, key: string, loc := #caller_location) -> bool {
	_, _, _ = table, key, loc
	unimplemented("semantic mutation is scheduled for implementation ticket 9")
}

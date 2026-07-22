package toml

import "base:runtime"
import "core:mem"
import "core:unicode/utf8"
import temporal "vendor/temporal"

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

@(private)
clone_validation_error :: proc(err: Semantic_Validation_Error) -> Clone_Error {
	if err == nil {
		return nil
	}
	if allocator_error, ok := err.(runtime.Allocator_Error); ok {
		return allocator_error
	}
	diagnostic := err.(Semantic_Diagnostic)
	if limit, ok := diagnostic.detail.(Mutation_Limit_Error); ok {
		clone_limit := Clone_Limit_Error(limit)
		return Clone_Diagnostic{
			detail = Clone_Diagnostic_Detail(clone_limit),
			temporal_error = diagnostic.temporal_error,
			path = diagnostic.path,
		}
	}
	kind := diagnostic.detail.(Semantic_Data_Error)
	clone_kind: Clone_Data_Error_Kind
	switch kind {
	case .Invalid_Document, .Invalid_Table:
		clone_kind = .Invalid_Document
	case .Invalid_Value_State:
		clone_kind = .Invalid_Value_State
	case .Invalid_Container, .Uninitialized_Container:
		clone_kind = .Invalid_Container
	case .Invalid_Key_Text, .Invalid_Value_Text:
		clone_kind = .Invalid_Text
	case .Duplicate_Key:
		clone_kind = .Duplicate_Key
	case .Invalid_Temporal:
		clone_kind = .Invalid_Temporal
	case .Cycle:
		clone_kind = .Cycle
	case .Ownership_Alias:
		clone_kind = .Ownership_Alias
	case .Allocator_Mismatch:
		clone_kind = .Allocator_Mismatch
	}
	return Clone_Diagnostic{
		detail = Clone_Diagnostic_Detail(clone_kind),
		temporal_error = diagnostic.temporal_error,
		path = diagnostic.path,
	}
}

@(private)
mutation_validation_error :: proc(err: Semantic_Validation_Error) -> Mutation_Error {
	if err == nil {
		return nil
	}
	if allocator_error, ok := err.(runtime.Allocator_Error); ok {
		return allocator_error
	}
	diagnostic := err.(Semantic_Diagnostic)
	if limit, ok := diagnostic.detail.(Mutation_Limit_Error); ok {
		return Mutation_Diagnostic{
			detail = limit,
			temporal_error = diagnostic.temporal_error,
			path = diagnostic.path,
		}
	}
	kind := diagnostic.detail.(Semantic_Data_Error)
	mutation_kind: Mutation_Data_Error_Kind
	switch kind {
	case .Invalid_Document, .Invalid_Table:
		mutation_kind = .Invalid_Table
	case .Invalid_Value_State:
		mutation_kind = .Invalid_Value_State
	case .Invalid_Container:
		mutation_kind = .Invalid_Value_State
	case .Uninitialized_Container:
		mutation_kind = .Allocator_Mismatch
	case .Invalid_Key_Text:
		mutation_kind = .Invalid_Key_Text
	case .Invalid_Value_Text:
		mutation_kind = .Invalid_Value_Text
	case .Duplicate_Key:
		mutation_kind = .Duplicate_Key
	case .Invalid_Temporal:
		mutation_kind = .Invalid_Temporal
	case .Cycle:
		mutation_kind = .Cycle
	case .Ownership_Alias:
		mutation_kind = .Ownership_Alias
	case .Allocator_Mismatch:
		mutation_kind = .Allocator_Mismatch
	}
	return Mutation_Diagnostic{
		detail = mutation_kind,
		temporal_error = diagnostic.temporal_error,
		path = diagnostic.path,
	}
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
	   doc.root.allocator.procedure == nil {
		return {}, clone_data_error(.Invalid_Document)
	}

	validation, validation_init_error := semantic_validation_state_init(
		allocator,
		doc.allocator,
		true,
		loc,
	)
	if validation_init_error != nil {
		return {}, validation_init_error
	}
	validation_error := semantic_validate_table(&validation, doc.root, true, loc)
	semantic_validation_state_destroy(&validation, loc)
	if validation_error != nil {
		return {}, clone_validation_error(validation_error)
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
	validation, validation_init_error := semantic_validation_state_init(allocator, loc = loc)
	if validation_init_error != nil {
		return {}, validation_init_error
	}
	validation_error := semantic_validate_value(&validation, value, loc)
	semantic_validation_state_destroy(&validation, loc)
	if validation_error != nil {
		return {}, clone_validation_error(validation_error)
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
	if table == nil {
		return Mutation_Diagnostic{
			detail = Mutation_Data_Error_Kind.Invalid_Table,
		}
	}
	table_raw := transmute(runtime.Raw_Dynamic_Array)table^
	if table_raw.allocator.procedure == nil {
		return Mutation_Diagnostic{
			detail = Mutation_Data_Error_Kind.Allocator_Mismatch,
		}
	}

	validation, validation_init_error := semantic_validation_state_init(
		table_raw.allocator,
		table_raw.allocator,
		true,
		loc,
	)
	if validation_init_error != nil {
		return validation_init_error
	}
	defer semantic_validation_state_destroy(&validation, loc)

	if table_error := semantic_validate_table(&validation, table^, true, loc); table_error != nil {
		return mutation_validation_error(table_error)
	}
	semantic_validation_state_reset(&validation)
	if path_error := semantic_push_path(&validation, key); path_error != nil {
		return mutation_validation_error(path_error)
	}
	if !utf8.valid_string(key) {
		return mutation_validation_error(semantic_diagnostic(
			&validation,
			Semantic_Data_Error.Invalid_Key_Text,
		))
	}
	if value_error := semantic_validate_value(&validation, value, loc); value_error != nil {
		return mutation_validation_error(value_error)
	}

	cleanup_gate := &validation.cleanup_gate
	existing_index := -1
	for entry, index in table {
		if entry.key == key {
			existing_index = index
			break
		}
	}
	if existing_index >= 0 {
		cloned, clone_error := clone_value_with_gate(
			value,
			table_raw.allocator,
			cleanup_gate,
			loc,
		)
		if clone_error != nil {
			if allocator_error, ok := clone_error.(runtime.Allocator_Error); ok {
				return allocator_error
			}
			unreachable()
		}
		old := table[existing_index].value
		table[existing_index].value = cloned
		destroy_value_with_gate(&old, cleanup_gate, loc)
		return nil
	}

	if len(table^) == max(int) {
		return mutation_validation_error(semantic_diagnostic(
			&validation,
			Mutation_Limit_Error.Size_Overflow,
		))
	}
	cloned_key, key_clone_error := clone_owned_string(key, table_raw.allocator, loc)
	if key_clone_error != nil {
		if allocator_error, ok := key_clone_error.(runtime.Allocator_Error); ok {
			return allocator_error
		}
		return mutation_validation_error(semantic_diagnostic(
			&validation,
			Semantic_Data_Error.Invalid_Key_Text,
		))
	}
	cloned_value, value_clone_error := clone_value_with_gate(
		value,
		table_raw.allocator,
		cleanup_gate,
		loc,
	)
	if value_clone_error != nil {
		release_owned_memory(cleanup_gate, raw_data(cloned_key), len(cloned_key), loc)
		if allocator_error, ok := value_clone_error.(runtime.Allocator_Error); ok {
			return allocator_error
		}
		unreachable()
	}
	new_table, table_error := make_owned_table(len(table^) + 1, table_raw.allocator, loc)
	if table_error != nil {
		release_owned_memory(cleanup_gate, raw_data(cloned_key), len(cloned_key), loc)
		destroy_value_with_gate(&cloned_value, cleanup_gate, loc)
		if allocator_error, ok := table_error.(runtime.Allocator_Error); ok {
			return allocator_error
		}
		return mutation_validation_error(semantic_diagnostic(
			&validation,
			Mutation_Limit_Error.Size_Overflow,
		))
	}
	if len(table^) > 0 {
		mem.copy_non_overlapping(
			raw_data(new_table),
			raw_data(table^),
			len(table^)*size_of(Entry),
		)
	}
	new_table[len(table^)] = {key = cloned_key, value = cloned_value}
	old_table := table^
	table^ = new_table
	release_owned_memory(
		cleanup_gate,
		raw_data(old_table),
		cap(old_table)*size_of(Entry),
		loc,
	)
	return nil
}

@(require_results)
remove :: proc(table: ^Table, key: string, loc := #caller_location) -> bool {
	if table == nil {
		return false
	}
	index := -1
	for entry, entry_index in table {
		if entry.key == key {
			index = entry_index
			break
		}
	}
	if index < 0 {
		return false
	}

	gate, gate_error := allocator_release_gate_init(table.allocator, loc)
	assert(gate_error == nil, "semantic owner allocator rejected mutation setup")
	release_owned_memory(&gate, raw_data(table[index].key), len(table[index].key), loc)
	table[index].key = ""
	destroy_value_with_gate(&table[index].value, &gate, loc)
	for next in index + 1 ..< len(table^) {
		table[next - 1] = table[next]
	}
	table[len(table^) - 1] = {}
	raw := transmute(runtime.Raw_Dynamic_Array)table^
	raw.len -= 1
	table^ = transmute(Table)raw
	return true
}

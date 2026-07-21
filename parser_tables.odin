package toml

import "base:runtime"
import "core:mem"

@(private)
Parser_Node_Location :: enum u8 {
	Table_Entry,
	Array_Element,
}

@(private)
Parser_Node :: struct {
	parent:            int,
	semantic_index:    int,
	location:          Parser_Node_Location,
	form:              Parse_Definition_Form,
	definition_range:  Source_Range,
	latest_element_id: int,
}

@(private)
Parser_Node_Array :: distinct [dynamic]Parser_Node

@(private)
parser_make_nodes :: proc(
	state: ^Parser_State,
	count: int,
	start, end: int,
) -> (Parser_Node_Array, Parse_Error) {
	if count < 0 || count > max(int)/size_of(Parser_Node) {
		return {}, parse_limit_error(
			state, .Size_Overflow, start, end, parser_path_snapshot(state),
		)
	}
	memory: rawptr
	if count > 0 {
		allocation_error: runtime.Allocator_Error
		memory, allocation_error = allocator_allocate(
			count*size_of(Parser_Node), state.allocator, true, state.loc,
		)
		if allocation_error != nil {
			return {}, allocation_error
		}
		if memory == nil {
			return {}, runtime.Allocator_Error.Out_Of_Memory
		}
	}
	raw := runtime.Raw_Dynamic_Array{memory, count, count, state.allocator}
	return transmute(Parser_Node_Array)raw, nil
}

@(private)
parser_append_node :: proc(
	state: ^Parser_State,
	node: Parser_Node,
	start, end: int,
) -> (int, Parse_Error) {
	if len(state.nodes) == max(int) {
		return 0, parse_limit_error(
			state, .Size_Overflow, start, end, parser_path_snapshot(state),
		)
	}
	replacement, err := parser_make_nodes(state, len(state.nodes)+1, start, end)
	if err != nil {
		return 0, err
	}
	if len(state.nodes) > 0 {
		mem.copy_non_overlapping(
			raw_data(replacement), raw_data(state.nodes),
			len(state.nodes)*size_of(Parser_Node),
		)
	}
	replacement[len(state.nodes)] = node
	old := state.nodes
	state.nodes = replacement
	release_owned_memory(
		&state.gate, raw_data(old), cap(old)*size_of(Parser_Node), state.loc,
	)
	return len(state.nodes), nil
}

@(private)
parser_release_nodes :: proc(state: ^Parser_State) {
	release_owned_memory(
		&state.gate,
		raw_data(state.nodes),
		cap(state.nodes)*size_of(Parser_Node),
		state.loc,
	)
	state.nodes = {}
}

@(private)
parser_node_value :: proc(state: ^Parser_State, node_id: int) -> (Value, bool) {
	if node_id <= 0 || node_id > len(state.nodes) {
		return {}, false
	}
	node := state.nodes[node_id-1]
	switch node.location {
	case .Table_Entry:
		parent, ok := parser_node_table(state, node.parent)
		if !ok || node.semantic_index < 0 || node.semantic_index >= len(parent) {
			return {}, false
		}
		return parent[node.semantic_index].value, true
	case .Array_Element:
		parent_value, ok := parser_node_value(state, node.parent)
		if !ok {
			return {}, false
		}
		array, array_ok := parent_value.(Array)
		if !array_ok || node.semantic_index < 0 || node.semantic_index >= len(array) {
			return {}, false
		}
		return array[node.semantic_index], true
	}
	unreachable()
}

@(private)
parser_node_table :: proc(state: ^Parser_State, node_id: int) -> (Table, bool) {
	if node_id == 0 {
		return state.root, true
	}
	value, ok := parser_node_value(state, node_id)
	if !ok {
		return {}, false
	}
	return value.(Table)
}

@(private)
parser_store_node_value :: proc(state: ^Parser_State, node_id: int, value: Value) {
	assert(0 < node_id && node_id <= len(state.nodes))
	node := state.nodes[node_id-1]
	switch node.location {
	case .Table_Entry:
		parent, ok := parser_node_table(state, node.parent)
		assert(ok && 0 <= node.semantic_index && node.semantic_index < len(parent))
		parent[node.semantic_index].value = value
	case .Array_Element:
		parent_value, ok := parser_node_value(state, node.parent)
		assert(ok)
		array, array_ok := parent_value.(Array)
		assert(array_ok && 0 <= node.semantic_index && node.semantic_index < len(array))
		array[node.semantic_index] = value
	}
}

@(private)
parser_store_node_table :: proc(state: ^Parser_State, node_id: int, table: Table) {
	if node_id == 0 {
		state.root = table
		return
	}
	parser_store_node_value(state, node_id, Value(table))
}

@(private)
parser_node_for_entry :: proc(state: ^Parser_State, parent, entry_index: int) -> int {
	for node, index in state.nodes {
		if node.parent == parent && node.location == .Table_Entry &&
		   node.semantic_index == entry_index {
			return index+1
		}
	}
	return 0
}

@(private)
parser_find_child :: proc(state: ^Parser_State, parent: int, key: string) -> int {
	table, ok := parser_node_table(state, parent)
	assert(ok)
	for entry, index in table {
		if entry.key == key {
			node_id := parser_node_for_entry(state, parent, index)
			assert(node_id != 0)
			return node_id
		}
	}
	return 0
}

@(private)
parser_append_child :: proc(
	state: ^Parser_State,
	parent: int,
	key: ^string,
	value: ^Value,
	form: Parse_Definition_Form,
	definition_range: Source_Range,
	start, end: int,
) -> (int, Parse_Error) {
	table, ok := parser_node_table(state, parent)
	assert(ok)
	entry_index := len(table)
	if err := parser_append_table_value(state, &table, key, value, start, end); err != nil {
		return 0, err
	}
	parser_store_node_table(state, parent, table)
	return parser_append_node(
		state,
		Parser_Node{
			parent = parent,
			semantic_index = entry_index,
			location = .Table_Entry,
			form = form,
			definition_range = definition_range,
		},
		start,
		end,
	)
}

@(private)
parser_path_copy :: proc(destination: ^Parser_Path_Stack, source: ^Parser_Path_Stack) {
	destination.count = source.count
	copy(destination.segments[:source.count], source.segments[:source.count])
	for index in source.count..<len(destination.segments) {
		destination.segments[index] = {}
	}
}

@(private)
parser_seed_active_path :: proc(state: ^Parser_State) {
	parser_path_pop_to(state, 0)
	state.container_path.count = state.active_path.count
	copy(
		state.container_path.segments[:state.active_path.count],
		state.active_path.segments[:state.active_path.count],
	)
}

@(private)
parser_definition_diagnostic :: proc(
	state: ^Parser_State,
	kind: Parse_Definition_Error_Kind,
	existing, attempted: Parse_Definition_Form,
	primary: Source_Byte_Range,
	related: Source_Range,
) -> Parse_Error {
	return parse_diagnostic(
		state,
		Parse_Diagnostic_Detail(Parse_Definition_Error{kind, existing, attempted}),
		primary.start,
		primary.end,
		parser_path_snapshot(state),
		Optional_Source_Range{related, true},
	)
}

@(private)
parser_node_related_range :: proc(state: ^Parser_State, node_id: int) -> Source_Range {
	node := state.nodes[node_id-1]
	if node.form == .Array_Of_Tables && node.latest_element_id != 0 {
		return state.nodes[node.latest_element_id-1].definition_range
	}
	return node.definition_range
}

@(private)
parser_parse_owned_path_key :: proc(
	state: ^Parser_State,
	start: int,
) -> (key: string, end: int, key_range: Source_Byte_Range, err: Parse_Error) {
	key_end, preflight_range, segment, ok := container_simple_key_segment(state, start)
	if !ok {
		return "", 0, {}, state.container_error
	}
	parser_path_push(state, segment)
	if state.container_path.count > state.max_depth {
		return "", 0, {}, parse_limit_error(
			state,
			.Maximum_Depth_Exceeded,
			preflight_range.start,
			preflight_range.end,
			parser_path_snapshot(state),
		)
	}
	key, end, key_range, err = parse_simple_key(state, start, parser_path_snapshot(state))
	if err != nil {
		return "", 0, {}, err
	}
	assert(end == key_end && key_range == preflight_range)
	return key, end, key_range, nil
}

@(private)
parser_create_table_child :: proc(
	state: ^Parser_State,
	parent: int,
	key: ^string,
	form: Parse_Definition_Form,
	key_range: Source_Byte_Range,
) -> (int, Parse_Error) {
	table, err := parser_make_table(
		state,
		0,
		key_range.start,
		key_range.end,
		parser_path_snapshot(state),
	)
	if err != nil {
		return 0, err
	}
	value := Value(table)
	value_owned := true
	defer if value_owned {
		destroy_value_with_gate(&value, &state.gate, state.loc)
	}
	node_id, append_error := parser_append_child(
		state,
		parent,
		key,
		&value,
		form,
		source_range(state.input, key_range.start, key_range.end),
		key_range.start,
		key_range.end,
	)
	if append_error != nil {
		return 0, append_error
	}
	value_owned = false
	return node_id, nil
}

@(private)
parser_descend_child :: proc(
	state: ^Parser_State,
	node_id: int,
	attempted: Parse_Definition_Form,
	key_range: Source_Byte_Range,
	remaining_path_start: int,
) -> (int, Parse_Error) {
	node := state.nodes[node_id-1]
	switch node.form {
	case .Implicit_Table, .Dotted_Table, .Array_Of_Tables_Element:
		return node_id, nil
	case .Standard_Table:
		if attempted == .Dotted_Table {
			return 0, parser_definition_diagnostic(
				state,
				.Table_Redefined,
				node.form,
				attempted,
				key_range,
				node.definition_range,
			)
		}
		return node_id, nil
	case .Array_Of_Tables:
		if attempted == .Dotted_Table {
			return 0, parser_definition_diagnostic(
				state,
				.Array_Of_Tables_Conflict,
				node.form,
				attempted,
				key_range,
				parser_node_related_range(state, node_id),
			)
		}
		assert(node.latest_element_id != 0)
		latest := node.latest_element_id
		latest_index := state.nodes[latest-1].semantic_index
		parser_path_push(state, Parse_Diagnostic_Path_Segment(Path_Index(latest_index)))
		if state.container_path.count > state.max_depth {
			return 0, parse_limit_error(
				state,
				.Maximum_Depth_Exceeded,
				key_range.start,
				key_range.end,
				parser_path_snapshot(state),
			)
		}
		return latest, nil
	case .Inline_Table, .Static_Array, .Key_Value:
		if !inline_complete_diagnostic_path(state, remaining_path_start) {
			return 0, state.container_error
		}
		kind := Parse_Definition_Error_Kind.Inline_Table_Extended
		if node.form == .Static_Array {
			kind = .Table_Array_Conflict
			if attempted == .Array_Of_Tables {
				kind = .Array_Of_Tables_Conflict
			}
		} else if node.form == .Key_Value {
			kind = .Non_Table_Path_Component
		}
		return 0, parser_definition_diagnostic(
			state, kind, node.form, attempted, key_range, node.definition_range,
		)
	}
	unreachable()
}

@(private)
parser_assignment_leaf_error :: proc(
	state: ^Parser_State,
	node_id: int,
	attempted: Parse_Definition_Form,
	key_range: Source_Byte_Range,
) -> Parse_Error {
	node := state.nodes[node_id-1]
	kind := Parse_Definition_Error_Kind.Duplicate_Key
	switch node.form {
	case .Implicit_Table, .Standard_Table:
		kind = .Table_Redefined
		if attempted == .Static_Array {
			kind = .Table_Array_Conflict
		}
	case .Dotted_Table:
		kind = .Dotted_Table_Redefined
		if attempted == .Static_Array {
			kind = .Table_Array_Conflict
		}
	case .Array_Of_Tables:
		kind = .Array_Of_Tables_Conflict
	case .Key_Value, .Inline_Table, .Static_Array, .Array_Of_Tables_Element:
	}
	return parser_definition_diagnostic(
		state,
		kind,
		node.form,
		attempted,
		key_range,
		parser_node_related_range(state, node_id),
	)
}

@(private)
parser_finish_document_line :: proc(
	state: ^Parser_State,
	start: int,
) -> (int, Parse_Error) {
	index := skip_horizontal_whitespace(state.input, start)
	if index < len(state.input) && state.input[index] == '#' {
		comment_error: Parse_Error
		index, comment_error = validate_comment(
			state, index, parser_path_snapshot(state),
		)
		if comment_error != nil {
			return 0, comment_error
		}
	}
	if index >= len(state.input) {
		return index, nil
	}
	if state.input[index] == '\r' {
		if index+1 >= len(state.input) || state.input[index+1] != '\n' {
			return 0, parse_lexical_error(
				state, .Invalid_Newline, index, index+1, parser_path_snapshot(state),
			)
		}
		return index+2, nil
	}
	if state.input[index] == '\n' {
		return index+1, nil
	}
	if state.input[index] < 0x20 || state.input[index] == 0x7f ||
	   state.input[index] >= 0x80 {
		return 0, parse_lexical_error(
			state,
			.Illegal_Character,
			index,
			index+utf8_scalar_size_at(state.input, index),
			parser_path_snapshot(state),
		)
	}
	return 0, parse_grammar_error(
		state,
		Parse_Syntax_Set{.Expression_End},
		found_syntax_at(state.input, index),
		index,
		index+utf8_scalar_size_at(state.input, index),
		parser_path_snapshot(state),
	)
}

@(private)
parser_path_separator_error :: proc(state: ^Parser_State, index: int) -> Parse_Error {
	if index >= len(state.input) {
		return nil
	}
	if state.input[index] == '\r' &&
	   (index+1 >= len(state.input) || state.input[index+1] != '\n') {
		return parse_lexical_error(
			state, .Invalid_Newline, index, index+1, parser_path_snapshot(state),
		)
	}
	if state.input[index] < 0x20 && state.input[index] != '\n' &&
	   state.input[index] != '\r' || state.input[index] == 0x7f ||
	   state.input[index] >= 0x80 {
		return parse_lexical_error(
			state,
			.Illegal_Character,
			index,
			index+utf8_scalar_size_at(state.input, index),
			parser_path_snapshot(state),
		)
	}
	return nil
}

@(private)
parse_key_value_expression :: proc(state: ^Parser_State, start: int) -> (int, Parse_Error) {
	parser_seed_active_path(state)
	current := state.active_table
	index := start
	expression_start := start

	for {
		key, key_end, key_range, key_error := parser_parse_owned_path_key(state, index)
		if key_error != nil {
			return 0, key_error
		}
		key_owned := true
		defer if key_owned {
			release_owned_text(state, &key)
		}
		index = skip_horizontal_whitespace(state.input, key_end)
		if separator_error := parser_path_separator_error(state, index); separator_error != nil {
			return 0, separator_error
		}
		if index < len(state.input) && state.input[index] == '.' {
			existing := parser_find_child(state, current, key)
			if existing == 0 {
				current, key_error = parser_create_table_child(
					state, current, &key, .Dotted_Table, key_range,
				)
				if key_error != nil {
					return 0, key_error
				}
				key_owned = false
			} else {
				release_owned_text(state, &key)
				key_owned = false
				current, key_error = parser_descend_child(
					state,
					existing,
					.Dotted_Table,
					key_range,
					skip_horizontal_whitespace(state.input, index+1),
				)
				if key_error != nil {
					return 0, key_error
				}
			}
			index = skip_horizontal_whitespace(state.input, index+1)
			continue
		}

		if index >= len(state.input) || state.input[index] != '=' {
			return 0, parse_grammar_error(
				state,
				Parse_Syntax_Set{.Equals},
				found_syntax_at(state.input, index),
				index,
				index,
				parser_path_snapshot(state),
			)
		}
		value_start := skip_horizontal_whitespace(state.input, index+1)
		attempted := Parse_Definition_Form.Key_Value
		if value_start < len(state.input) && state.input[value_start] == '[' {
			attempted = .Static_Array
		} else if value_start < len(state.input) && state.input[value_start] == '{' {
			attempted = .Inline_Table
		}
		if existing := parser_find_child(state, current, key); existing != 0 {
			return 0, parser_assignment_leaf_error(
				state, existing, attempted, key_range,
			)
		}

		index = value_start
		if index >= len(state.input) || state.input[index] == '\n' ||
		   state.input[index] == '\r' || state.input[index] == '#' {
			end := index+min(1, len(state.input)-index)
			if index+1 < len(state.input) && state.input[index] == '\r' &&
			   state.input[index+1] == '\n' {
				end = index+2
			}
			return 0, parse_grammar_error(
				state,
				Parse_Syntax_Set{.Value},
				found_syntax_at(state.input, index),
				index,
				end,
				parser_path_snapshot(state),
			)
		}
		value, value_end, form, ok := parser_parse_value(state, index, .Document)
		if !ok {
			return 0, state.container_error
		}
		value_owned := true
		defer if value_owned {
			destroy_value_with_gate(&value, &state.gate, state.loc)
		}
		line_end, line_error := parser_finish_document_line(state, value_end)
		if line_error != nil {
			return 0, line_error
		}
		definition_range := source_range(state.input, expression_start, value_end)
		_, append_error := parser_append_child(
			state,
			current,
			&key,
			&value,
			form,
			definition_range,
			expression_start,
			value_end,
		)
		if append_error != nil {
			return 0, append_error
		}
		key_owned = false
		value_owned = false
		return line_end, nil
	}
}

@(private)
parser_standard_leaf :: proc(
	state: ^Parser_State,
	parent: int,
	key: ^string,
	key_range: Source_Byte_Range,
) -> (int, Parse_Error) {
	existing := parser_find_child(state, parent, key^)
	if existing == 0 {
		return parser_create_table_child(
			state, parent, key, .Standard_Table, key_range,
		)
	}
	node := &state.nodes[existing-1]
	if node.form == .Implicit_Table {
		node.form = .Standard_Table
		return existing, nil
	}
	kind: Parse_Definition_Error_Kind
	switch node.form {
	case .Standard_Table:
		kind = .Table_Redefined
	case .Dotted_Table:
		kind = .Dotted_Table_Redefined
	case .Inline_Table:
		kind = .Inline_Table_Extended
	case .Static_Array:
		kind = .Table_Array_Conflict
	case .Array_Of_Tables:
		kind = .Array_Of_Tables_Conflict
	case .Key_Value:
		kind = .Non_Table_Path_Component
	case .Implicit_Table, .Array_Of_Tables_Element:
		unreachable()
	}
	return 0, parser_definition_diagnostic(
		state,
		kind,
		node.form,
		.Standard_Table,
		key_range,
		parser_node_related_range(state, existing),
	)
}

@(private)
parser_append_aot_element :: proc(
	state: ^Parser_State,
	container_id: int,
	key_range: Source_Byte_Range,
) -> (int, Parse_Error) {
	container_value, ok := parser_node_value(state, container_id)
	assert(ok)
	array, array_ok := container_value.(Array)
	assert(array_ok)
	prospective_index := len(array)
	parser_path_push(
		state, Parse_Diagnostic_Path_Segment(Path_Index(prospective_index)),
	)
	if state.container_path.count > state.max_depth {
		return 0, parse_limit_error(
			state,
			.Maximum_Depth_Exceeded,
			key_range.start,
			key_range.end,
			parser_path_snapshot(state),
		)
	}
	table, table_error := parser_make_table(
		state, 0, key_range.start, key_range.end, parser_path_snapshot(state),
	)
	if table_error != nil {
		return 0, table_error
	}
	value := Value(table)
	value_owned := true
	defer if value_owned {
		destroy_value_with_gate(&value, &state.gate, state.loc)
	}
	if append_error := parser_append_array_value(
		state, &array, &value, key_range.start, key_range.end,
	); append_error != nil {
		return 0, append_error
	}
	parser_store_node_value(state, container_id, Value(array))
	value_owned = false
	element_id, node_error := parser_append_node(
		state,
		Parser_Node{
			parent = container_id,
			semantic_index = prospective_index,
			location = .Array_Element,
			form = .Array_Of_Tables_Element,
			definition_range = source_range(
				state.input, key_range.start, key_range.end,
			),
		},
		key_range.start,
		key_range.end,
	)
	if node_error != nil {
		return 0, node_error
	}
	state.nodes[container_id-1].latest_element_id = element_id
	return element_id, nil
}

@(private)
parser_aot_leaf :: proc(
	state: ^Parser_State,
	parent: int,
	key: ^string,
	key_range: Source_Byte_Range,
) -> (container_id, element_id: int, err: Parse_Error) {
	container_id = parser_find_child(state, parent, key^)
	if container_id == 0 {
		array, array_error := parser_make_array(
			state, 0, key_range.start, key_range.end,
		)
		if array_error != nil {
			return 0, 0, array_error
		}
		value := Value(array)
		value_owned := true
		defer if value_owned {
			destroy_value_with_gate(&value, &state.gate, state.loc)
		}
		container_id, array_error = parser_append_child(
			state,
			parent,
			key,
			&value,
			.Array_Of_Tables,
			source_range(state.input, key_range.start, key_range.end),
			key_range.start,
			key_range.end,
		)
		if array_error != nil {
			return 0, 0, array_error
		}
		value_owned = false
	} else {
		node := state.nodes[container_id-1]
		if node.form != .Array_Of_Tables {
			return 0, 0, parser_definition_diagnostic(
				state,
				.Array_Of_Tables_Conflict,
				node.form,
				.Array_Of_Tables,
				key_range,
				parser_node_related_range(state, container_id),
			)
		}
		release_owned_text(state, key)
	}
	element_id, err = parser_append_aot_element(state, container_id, key_range)
	return container_id, element_id, err
}

@(private)
parse_header_expression :: proc(state: ^Parser_State, start: int) -> (int, Parse_Error) {
	aot := start+1 < len(state.input) && state.input[start+1] == '['
	index := start+1
	if aot {
		index += 1
	}
	parser_path_pop_to(state, 0)
	current := 0
	index = skip_horizontal_whitespace(state.input, index)
	leaf_id := 0
	container_id := 0

	for {
		if index >= len(state.input) || state.input[index] == ']' ||
		   state.input[index] == '\n' || state.input[index] == '\r' {
			return 0, parse_grammar_error(
				state,
				Parse_Syntax_Set{.Key},
				found_syntax_at(state.input, index),
				index,
				index+min(1, len(state.input)-index),
				parser_path_snapshot(state),
			)
		}
		key, key_end, key_range, key_error := parser_parse_owned_path_key(state, index)
		if key_error != nil {
			return 0, key_error
		}
		key_owned := true
		defer if key_owned {
			release_owned_text(state, &key)
		}
		index = skip_horizontal_whitespace(state.input, key_end)
		if separator_error := parser_path_separator_error(state, index); separator_error != nil {
			return 0, separator_error
		}
		if index < len(state.input) && state.input[index] == '.' {
			existing := parser_find_child(state, current, key)
			if existing == 0 {
				current, key_error = parser_create_table_child(
					state, current, &key, .Implicit_Table, key_range,
				)
				if key_error != nil {
					return 0, key_error
				}
				key_owned = false
			} else {
				release_owned_text(state, &key)
				key_owned = false
				attempted := Parse_Definition_Form.Standard_Table
				if aot {
					attempted = .Array_Of_Tables
				}
				current, key_error = parser_descend_child(
					state,
					existing,
					attempted,
					key_range,
					skip_horizontal_whitespace(state.input, index+1),
				)
				if key_error != nil {
					return 0, key_error
				}
			}
			index = skip_horizontal_whitespace(state.input, index+1)
			continue
		}

		closing_count := 1
		if aot {
			closing_count = 2
		}
		for offset in 0..<closing_count {
			closing_index := index+offset
			if closing_index >= len(state.input) || state.input[closing_index] != ']' {
				expected := Parse_Syntax.Table_Header
				if aot {
					expected = .Array_Of_Tables_Header
				}
				return 0, parse_grammar_error(
					state,
					Parse_Syntax_Set{expected},
					found_syntax_at(state.input, closing_index),
					closing_index,
					closing_index+min(1, len(state.input)-closing_index),
					parser_path_snapshot(state),
				)
			}
		}

		if aot {
			container_id, leaf_id, key_error = parser_aot_leaf(
				state, current, &key, key_range,
			)
			if key_error != nil {
				return 0, key_error
			}
			key_owned = false
		} else {
			leaf_id, key_error = parser_standard_leaf(
				state, current, &key, key_range,
			)
			if key_error != nil {
				return 0, key_error
			}
			if key != "" {
				release_owned_text(state, &key)
			}
			key_owned = false
		}
		index += closing_count
		break
	}

	line_end, line_error := parser_finish_document_line(state, index)
	if line_error != nil {
		return 0, line_error
	}
	header_range := source_range(state.input, start, index)
	state.nodes[leaf_id-1].definition_range = header_range
	if container_id != 0 {
		container_value, container_ok := parser_node_value(state, container_id)
		assert(container_ok)
		array, array_ok := container_value.(Array)
		assert(array_ok)
		if len(array) == 1 {
			state.nodes[container_id-1].definition_range = header_range
		}
	}
	state.active_table = leaf_id
	parser_path_copy(&state.active_path, &state.container_path)
	return line_end, nil
}

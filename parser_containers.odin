package toml

import "base:runtime"
import "core:mem"

@(private)
Parser_Value_Context :: enum u8 {
	Document,
	Array,
	Inline_Table,
}

@(private)
Parser_Path_Segment :: union #no_nil {
	Source_Byte_Range,
	Path_Index,
}

@(private)
Parser_Path_Stack :: struct {
	segments: [257]Parser_Path_Segment,
	count:    int,
}

@(private)
parser_path_push :: proc(state: ^Parser_State, segment: Parser_Path_Segment) {
	assert(state.container_path.count < len(state.container_path.segments))
	state.container_path.segments[state.container_path.count] = segment
	state.container_path.count += 1
}

@(private)
parser_path_pop_to :: proc(state: ^Parser_State, count: int) {
	assert(0 <= count && count <= state.container_path.count)
	state.container_path.count = count
}

@(private)
parser_path_snapshot_segment :: proc(
	state: ^Parser_State,
	segment: Parser_Path_Segment,
) -> Parse_Diagnostic_Path_Segment {
	switch item in segment {
	case Source_Byte_Range:
		return parse_path_segment_for_source(state, item)
	case Path_Index:
		return Parse_Diagnostic_Path_Segment(item)
	}
	unreachable()
}

@(private)
parser_path_snapshot :: proc(state: ^Parser_State) -> Parse_Diagnostic_Path {
	result: Parse_Diagnostic_Path
	count := state.container_path.count
	result.total_segment_count = u16(count)
	if count <= PARSE_DIAGNOSTIC_PATH_CAPACITY {
		result.segment_count = u8(count)
		result.prefix_count = u8(count)
		for index in 0..<count {
			result.segments[index] = parser_path_snapshot_segment(
				state, state.container_path.segments[index],
			)
		}
		return result
	}
	result.segment_count = PARSE_DIAGNOSTIC_PATH_CAPACITY
	result.prefix_count = PARSE_DIAGNOSTIC_PATH_PREFIX_COUNT
	result.omitted_segment_count = u16(count-PARSE_DIAGNOSTIC_PATH_CAPACITY)
	result.truncated = true
	for index in 0..<PARSE_DIAGNOSTIC_PATH_PREFIX_COUNT {
		result.segments[index] = parser_path_snapshot_segment(
			state, state.container_path.segments[index],
		)
	}
	tail_count := PARSE_DIAGNOSTIC_PATH_CAPACITY-PARSE_DIAGNOSTIC_PATH_PREFIX_COUNT
	for offset in 0..<tail_count {
		result.segments[PARSE_DIAGNOSTIC_PATH_PREFIX_COUNT+offset] =
			parser_path_snapshot_segment(
				state, state.container_path.segments[count-tail_count+offset],
			)
	}
	return result
}

@(private)
container_grammar_error :: proc(
	state: ^Parser_State,
	expected: Parse_Syntax_Set,
	found: Parse_Syntax,
	start, end: int,
) -> Parse_Error {
	return parse_grammar_error(
		state, expected, found, start, end, .Current,
	)
}

@(private)
container_limit_error :: proc(
	state: ^Parser_State,
	kind: Parse_Limit_Error,
	start, end: int,
) -> Parse_Error {
	return parse_limit_error(
		state, kind, start, end, .Current,
	)
}

@(private)
container_store_error :: proc(state: ^Parser_State, err: Parse_Error) -> bool {
	assert(err != nil)
	state.container_error = err
	return false
}

@(private)
container_fail_grammar :: proc(
	state: ^Parser_State,
	expected: Parse_Syntax_Set,
	found: Parse_Syntax,
	start, end: int,
) -> bool {
	return container_store_error(
		state, container_grammar_error(state, expected, found, start, end),
	)
}

@(private)
container_fail_limit :: proc(
	state: ^Parser_State,
	kind: Parse_Limit_Error,
	start, end: int,
) -> bool {
	return container_store_error(
		state, container_limit_error(state, kind, start, end),
	)
}

@(private)
container_make_table :: proc(
	state: ^Parser_State,
	count: int,
	start, end: int,
) -> (Table, Parse_Error) {
	return parser_make_table(
		state, count, start, end, .Current,
	)
}

@(private)
container_make_table_capacity :: proc(
	state: ^Parser_State,
	count, capacity: int,
	start, end: int,
) -> (Table, Parse_Error) {
	return parser_make_table_capacity(
		state, count, capacity, start, end, .Current,
	)
}

@(private)
parser_make_array_capacity :: proc(
	state: ^Parser_State,
	count, capacity: int,
	start, end: int,
) -> (Array, Parse_Error) {
	if count < 0 || capacity < count || capacity > max(int)/size_of(Value) {
		return {}, container_limit_error(state, .Size_Overflow, start, end)
	}
	memory: rawptr
	if capacity > 0 {
		allocation_error: runtime.Allocator_Error
		memory, allocation_error = allocator_allocate(
			capacity*size_of(Value),
			state.allocator,
			true,
			state.loc,
		)
		if allocation_error != nil {
			return {}, allocation_error
		}
		if memory == nil {
			return {}, runtime.Allocator_Error.Out_Of_Memory
		}
	}
	raw := runtime.Raw_Dynamic_Array{
		data = memory,
		len = count,
		cap = capacity,
		allocator = state.allocator,
	}
	return transmute(Array)raw, nil
}

@(private)
parser_make_array :: proc(
	state: ^Parser_State,
	count: int,
	start, end: int,
) -> (Array, Parse_Error) {
	return parser_make_array_capacity(state, count, count, start, end)
}

@(private)
parser_append_array_value :: proc(
	state: ^Parser_State,
	array: ^Array,
	value: ^Value,
	start, end: int,
) -> Parse_Error {
	index := len(array^)
	if index < cap(array^) {
		raw := transmute(runtime.Raw_Dynamic_Array)array^
		raw.len = index+1
		array^ = transmute(Array)raw
		array^[index] = value^
		value^ = {}
		return nil
	}
	capacity, capacity_ok := parser_growth_capacity(
		cap(array^), index+1, size_of(Value),
	)
	if !capacity_ok {
		return container_limit_error(state, .Size_Overflow, start, end)
	}
	replacement, err := parser_make_array_capacity(
		state, index+1, capacity, start, end,
	)
	if err != nil {
		return err
	}
	if index > 0 {
		mem.copy_non_overlapping(
			raw_data(replacement), raw_data(array^), index*size_of(Value),
		)
	}
	replacement[index] = value^
	value^ = {}
	old := array^
	array^ = replacement
	release_owned_memory(&state.gate, raw_data(old), cap(old)*size_of(Value), state.loc)
	return nil
}

@(private)
parser_append_table_value :: proc(
	state: ^Parser_State,
	table: ^Table,
	key: ^string,
	value: ^Value,
	start, end: int,
) -> Parse_Error {
	index := len(table^)
	if index < cap(table^) {
		raw := transmute(runtime.Raw_Dynamic_Array)table^
		raw.len = index+1
		table^ = transmute(Table)raw
		table^[index] = {key = key^, value = value^}
		key^ = ""
		value^ = {}
		return nil
	}
	capacity, capacity_ok := parser_growth_capacity(
		cap(table^), index+1, size_of(Entry),
	)
	if !capacity_ok {
		return container_limit_error(state, .Size_Overflow, start, end)
	}
	replacement, err := container_make_table_capacity(
		state, index+1, capacity, start, end,
	)
	if err != nil {
		return err
	}
	if index > 0 {
		mem.copy_non_overlapping(
			raw_data(replacement), raw_data(table^), index*size_of(Entry),
		)
	}
	replacement[index] = {key = key^, value = value^}
	key^ = ""
	value^ = {}
	old := table^
	table^ = replacement
	release_owned_memory(&state.gate, raw_data(old), cap(old)*size_of(Entry), state.loc)
	return nil
}

@(private)
skip_container_trivia :: proc(
	state: ^Parser_State,
	start: int,
) -> (int, Parse_Error) {
	index := start
	for index < len(state.input) {
		switch state.input[index] {
		case ' ', '\t', '\n':
			index += 1
		case '\r':
			if index+1 >= len(state.input) || state.input[index+1] != '\n' {
				return 0, parse_lexical_error(
					state, .Invalid_Newline, index, index+1, .Current,
				)
			}
			index += 2
		case '#':
			err: Parse_Error
			index, err = validate_comment(
				state, index, .Current,
			)
			if err != nil {
				return 0, err
			}
		case:
			if state.input[index] < 0x20 || state.input[index] == 0x7f || state.input[index] >= 0x80 {
				return 0, parse_lexical_error(
					state,
					.Illegal_Character,
					index,
					index+utf8_scalar_size_at(state.input, index),
					.Current,
				)
			}
			return index, nil
		}
	}
	return index, nil
}

@(private)
container_try_make_array :: proc(
	state: ^Parser_State,
	count, start, end: int,
) -> (Array, bool) {
	array, err := parser_make_array(state, count, start, end)
	if err != nil {
		container_store_error(state, err)
		return {}, false
	}
	return array, true
}

@(private)
container_try_make_table :: proc(
	state: ^Parser_State,
	count, start, end: int,
) -> (Table, bool) {
	table, err := container_make_table(state, count, start, end)
	if err != nil {
		container_store_error(state, err)
		return {}, false
	}
	return table, true
}

@(private)
container_try_append_array :: proc(
	state: ^Parser_State,
	array: ^Array,
	value: ^Value,
	start, end: int,
) -> bool {
	if err := parser_append_array_value(state, array, value, start, end); err != nil {
		return container_store_error(state, err)
	}
	return true
}

@(private)
container_try_trivia :: proc(
	state: ^Parser_State,
	start: int,
) -> (int, bool) {
	index, err := skip_container_trivia(state, start)
	if err != nil {
		container_store_error(state, err)
		return 0, false
	}
	return index, true
}

@(private)
parser_parse_array :: proc(
	state: ^Parser_State,
	start: int,
) -> (result: Value, end: int, ok: bool) {
	base_path_count := state.container_path.count
	array: Array
	array, ok = container_try_make_array(state, 0, start, start+1)
	if !ok {
		return {}, 0, false
	}
	owned := true
	defer if owned {
		value := Value(array)
		destroy_value_with_gate(&value, &state.gate, state.loc)
	}
	range_id, range_error := parser_append_binding_range(
		state, {start, start+1}, start, start+1,
	)
	if range_error != nil {
		container_store_error(state, range_error)
		return {}, 0, false
	}

	index := start+1
	index, ok = container_try_trivia(state, index)
	if !ok {
		return {}, 0, false
	}
	if index < len(state.input) && state.input[index] == ']' {
		parser_binding_range_finish(state, range_id, start, index+1)
		state.last_binding_range_id = range_id
		owned = false
		return Value(array), index+1, true
	}

	for {
		parser_path_pop_to(state, base_path_count)
		parser_path_push(state, Parser_Path_Segment(Path_Index(len(array))))
		if state.container_path.count > state.max_depth {
			container_fail_limit(
				state, .Maximum_Depth_Exceeded,
				index, index+min(1, len(state.input)-index),
			)
			return {}, 0, false
		}
		if index >= len(state.input) || state.input[index] == ',' || state.input[index] == ']' {
			container_fail_grammar(
				state, Parse_Syntax_Set{.Value}, found_syntax_at(state.input, index),
				index, index+min(1, len(state.input)-index),
			)
			return {}, 0, false
		}
		child: Value
		child_end: int
		child, child_end, _, ok = parser_parse_value(state, index, .Array)
		if !ok {
			return {}, 0, false
		}
		child_range_id := state.last_binding_range_id
		child_owned := true
		defer if child_owned {
			destroy_value_with_gate(&child, &state.gate, state.loc)
		}
		if !container_try_append_array(state, &array, &child, index, child_end) {
			return {}, 0, false
		}
		parser_binding_range_attach(state, child_range_id, range_id, len(array)-1)
		child_owned = false

		index, ok = container_try_trivia(state, child_end)
		if !ok {
			return {}, 0, false
		}
		if index < len(state.input) && state.input[index] == ']' {
			parser_path_pop_to(state, base_path_count)
			parser_binding_range_finish(state, range_id, start, index+1)
			state.last_binding_range_id = range_id
			owned = false
			return Value(array), index+1, true
		}
		if index >= len(state.input) || state.input[index] != ',' {
			container_fail_grammar(
				state, Parse_Syntax_Set{.Comma, .Right_Bracket},
				found_syntax_at(state.input, index),
				index, index+min(1, len(state.input)-index),
			)
			return {}, 0, false
		}
		parser_path_pop_to(state, base_path_count)
		index, ok = container_try_trivia(state, index+1)
		if !ok {
			return {}, 0, false
		}
		if index < len(state.input) && state.input[index] == ']' {
			parser_binding_range_finish(state, range_id, start, index+1)
			state.last_binding_range_id = range_id
			owned = false
			return Value(array), index+1, true
		}
	}
}

@(private)
Inline_Entry_Metadata :: struct {
	form:  Parse_Definition_Form,
	range: Source_Byte_Range,
	child: ^Inline_Table_State,
}

@(private)
Inline_Metadata_Array :: distinct [dynamic]Inline_Entry_Metadata

@(private)
Inline_Table_State :: struct {
	table:         Table,
	metadata:      Inline_Metadata_Array,
	parent:        ^Inline_Table_State,
	parent_entry:  int,
	binding_range_id: int,
}

@(private)
inline_make_metadata :: proc(
	state: ^Parser_State,
	count: int,
	start, end: int,
) -> (Inline_Metadata_Array, Parse_Error) {
	if count < 0 || count > max(int)/size_of(Inline_Entry_Metadata) {
		return {}, container_limit_error(state, .Size_Overflow, start, end)
	}
	memory: rawptr
	if count > 0 {
		allocation_error: runtime.Allocator_Error
		memory, allocation_error = allocator_allocate(
			count*size_of(Inline_Entry_Metadata), state.allocator, true, state.loc,
		)
		if allocation_error != nil {
			return {}, allocation_error
		}
		if memory == nil {
			return {}, runtime.Allocator_Error.Out_Of_Memory
		}
	}
	raw := runtime.Raw_Dynamic_Array{memory, count, count, state.allocator}
	return transmute(Inline_Metadata_Array)raw, nil
}

@(private)
inline_append_metadata :: proc(
	state: ^Parser_State,
	table_state: ^Inline_Table_State,
	metadata: Inline_Entry_Metadata,
	start, end: int,
) -> Parse_Error {
	replacement, err := inline_make_metadata(
		state, len(table_state.metadata)+1, start, end,
	)
	if err != nil {
		return err
	}
	if len(table_state.metadata) > 0 {
		mem.copy_non_overlapping(
			raw_data(replacement), raw_data(table_state.metadata),
			len(table_state.metadata)*size_of(Inline_Entry_Metadata),
		)
	}
	replacement[len(table_state.metadata)] = metadata
	old := table_state.metadata
	table_state.metadata = replacement
	release_owned_memory(
		&state.gate, raw_data(old), cap(old)*size_of(Inline_Entry_Metadata), state.loc,
	)
	return nil
}

@(private)
inline_sync_parent :: proc(table_state: ^Inline_Table_State) {
	if table_state.parent != nil {
		table_state.parent.table[table_state.parent_entry].value = Value(table_state.table)
	}
}

@(private)
inline_cleanup_scratch :: proc(state: ^Parser_State, table_state: ^Inline_Table_State) {
	if table_state == nil {
		return
	}
	for metadata in table_state.metadata {
		if metadata.child != nil {
			inline_cleanup_scratch(state, metadata.child)
			release_owned_memory(&state.gate, metadata.child, size_of(Inline_Table_State), state.loc)
		}
	}
	release_owned_memory(
		&state.gate,
		raw_data(table_state.metadata),
		cap(table_state.metadata)*size_of(Inline_Entry_Metadata),
		state.loc,
	)
	table_state.metadata = {}
}

@(private)
inline_find_key :: proc(table_state: ^Inline_Table_State, key: string) -> int {
	for entry, index in table_state.table {
		if entry.key == key {
			return index
		}
	}
	return -1
}

@(private)
inline_definition_error :: proc(
	state: ^Parser_State,
	kind: Parse_Definition_Error_Kind,
	existing, attempted: Parse_Definition_Form,
	primary: Source_Byte_Range,
	related: Source_Byte_Range,
) -> Parse_Error {
	return parse_diagnostic(
		state,
		Parse_Diagnostic_Detail(Parse_Definition_Error{kind, existing, attempted}),
		primary.start,
		primary.end,
		.Current,
		Optional_Source_Range{
			source_range(state.input, related.start, related.end), true,
		},
	)
}

@(private)
inline_new_child :: proc(
	state: ^Parser_State,
	parent: ^Inline_Table_State,
	parent_entry: int,
	start, end: int,
) -> (^Inline_Table_State, Parse_Error) {
	memory, allocation_error := allocator_allocate(size_of(Inline_Table_State), state.allocator, true, state.loc)
	if allocation_error != nil {
		return nil, allocation_error
	}
	if memory == nil {
		return nil, runtime.Allocator_Error.Out_Of_Memory
	}
	child := (^Inline_Table_State)(memory)
	child.parent = parent
	child.parent_entry = parent_entry
	err: Parse_Error
	child.table, err = container_make_table(state, 0, start, end)
	if err != nil {
		release_owned_memory(&state.gate, memory, size_of(Inline_Table_State), state.loc)
		return nil, err
	}
	child.binding_range_id, err = parser_append_binding_range(
		state, {start, end}, start, end,
	)
	if err != nil {
		destroy_table_with_gate(&child.table, &state.gate, state.loc)
		release_owned_memory(&state.gate, memory, size_of(Inline_Table_State), state.loc)
		return nil, err
	}
	parser_binding_range_attach(
		state, child.binding_range_id, parent.binding_range_id, parent_entry,
	)
	return child, nil
}

@(private)
inline_append_entry :: proc(
	state: ^Parser_State,
	table_state: ^Inline_Table_State,
	key: ^string,
	value: ^Value,
	metadata: Inline_Entry_Metadata,
	start, end: int,
) -> Parse_Error {
	if err := parser_append_table_value(
		state, &table_state.table, key, value, start, end,
	); err != nil {
		return err
	}
	inline_sync_parent(table_state)
	return inline_append_metadata(state, table_state, metadata, start, end)
}

@(private)
container_simple_key_segment :: proc(
	state: ^Parser_State,
	start: int,
) -> (end: int, key_range: Source_Byte_Range, segment: Parser_Path_Segment, ok: bool) {
	path := Parser_Diagnostic_Path.Current
	if start >= len(state.input) {
		container_store_error(
			state,
			parse_grammar_error(
				state,
				Parse_Syntax_Set{.Key},
				.End_Of_Input,
				start,
				start,
				path,
			),
		)
		return 0, {}, {}, false
	}

	character := state.input[start]
	if character != '"' && character != '\'' {
		if !is_bare_key_byte(character) {
			scalar_end := start+utf8_scalar_size_at(state.input, start)
			container_store_error(
				state,
				parse_lexical_error(
					state, .Invalid_Bare_Key, start, scalar_end, path,
				),
			)
			return 0, {}, {}, false
		}
		end = start+1
		for end < len(state.input) && is_bare_key_byte(state.input[end]) {
			end += 1
		}
		key_range = {start, end}
		return end, key_range, Parser_Path_Segment(key_range), true
	}

	if start+2 < len(state.input) && state.input[start+1] == character &&
	   state.input[start+2] == character {
		container_store_error(
			state,
			parse_lexical_error(
				state, .Invalid_Bare_Key, start, start+3, path,
			),
		)
		return 0, {}, {}, false
	}
	kind := Quoted_Text_Kind.Basic
	if character == '\'' {
		kind = .Literal
	}
	err: Parse_Error
	end, _, err = quoted_text_scan(state, start, kind, {}, path)
	if err != nil {
		container_store_error(state, err)
		return 0, {}, {}, false
	}
	key_range = {start, end}
	return end, key_range, Parser_Path_Segment(key_range), true
}

@(private)
container_try_simple_key :: proc(
	state: ^Parser_State,
	start: int,
) -> (string, int, Source_Byte_Range, bool) {
	key, end, key_range, err := parse_simple_key(
		state, start, .Current,
	)
	if err != nil {
		container_store_error(state, err)
		return "", 0, {}, false
	}
	return key, end, key_range, true
}

@(private)
container_try_inline_child :: proc(
	state: ^Parser_State,
	parent: ^Inline_Table_State,
	parent_entry, start, end: int,
) -> (^Inline_Table_State, bool) {
	child, err := inline_new_child(state, parent, parent_entry, start, end)
	if err != nil {
		container_store_error(state, err)
		return nil, false
	}
	return child, true
}

@(private)
inline_complete_diagnostic_path :: proc(
	state: ^Parser_State,
	start: int,
) -> bool {
	index := skip_horizontal_whitespace(state.input, start)
	for {
		if index >= len(state.input) {
			return true
		}
		key_end, key_range, key_segment, ok := container_simple_key_segment(state, index)
		if !ok {
			return false
		}
		parser_path_push(state, key_segment)
		if state.container_path.count > state.max_depth {
			return container_fail_limit(
				state, .Maximum_Depth_Exceeded, key_range.start, key_range.end,
			)
		}
		index = skip_horizontal_whitespace(state.input, key_end)
		if index >= len(state.input) || state.input[index] != '.' {
			return true
		}
		index = skip_horizontal_whitespace(state.input, index+1)
	}
}

@(private)
container_try_inline_append :: proc(
	state: ^Parser_State,
	table_state: ^Inline_Table_State,
	key: ^string,
	value: ^Value,
	metadata: Inline_Entry_Metadata,
	start, end: int,
) -> bool {
	if err := inline_append_entry(
		state, table_state, key, value, metadata, start, end,
	); err != nil {
		return container_store_error(state, err)
	}
	return true
}

@(private)
parser_parse_inline_table :: proc(
	state: ^Parser_State,
	start: int,
) -> (result: Value, end: int, ok: bool) {
	base_path_count := state.container_path.count
	root: Inline_Table_State
	root.parent_entry = -1
	root.table, ok = container_try_make_table(state, 0, start, start+1)
	if !ok {
		return {}, 0, false
	}
	range_error: Parse_Error
	root.binding_range_id, range_error = parser_append_binding_range(
		state, {start, start+1}, start, start+1,
	)
	if range_error != nil {
		container_store_error(state, range_error)
		destroy_table_with_gate(&root.table, &state.gate, state.loc)
		return {}, 0, false
	}
	owned := true
	defer {
		inline_cleanup_scratch(state, &root)
		if owned {
			destroy_table_with_gate(&root.table, &state.gate, state.loc)
		}
	}

	index := start+1
	index, ok = container_try_trivia(state, index)
	if !ok {
		return {}, 0, false
	}
	if index < len(state.input) && state.input[index] == '}' {
		parser_binding_range_finish(state, root.binding_range_id, start, index+1)
		state.last_binding_range_id = root.binding_range_id
		owned = false
		return Value(root.table), index+1, true
	}

	for {
		parser_path_pop_to(state, base_path_count)
		pair_start := index
		current := &root
		leaf_key: string
		leaf_range: Source_Byte_Range
		leaf_owned := true
		defer if leaf_owned {
			release_owned_text(state, &leaf_key)
		}

		for {
			if index >= len(state.input) || state.input[index] == '}' || state.input[index] == ',' ||
			   state.input[index] == '\n' || state.input[index] == '\r' {
				container_fail_grammar(
					state, Parse_Syntax_Set{.Key}, found_syntax_at(state.input, index),
					index, index+min(1, len(state.input)-index),
				)
				return {}, 0, false
			}
			key_end, key_range, key_segment, key_ok := container_simple_key_segment(state, index)
			if !key_ok {
				return {}, 0, false
			}
			parser_path_push(state, key_segment)
			if state.container_path.count > state.max_depth {
				container_fail_limit(
					state, .Maximum_Depth_Exceeded, key_range.start, key_range.end,
				)
				return {}, 0, false
			}
			key, decoded_end, decoded_range, decoded_ok := container_try_simple_key(state, index)
			if !decoded_ok {
				return {}, 0, false
			}
			assert(decoded_end == key_end && decoded_range == key_range)
			index = skip_horizontal_whitespace(state.input, key_end)
			if index >= len(state.input) || state.input[index] != '.' {
				leaf_key = key
				leaf_range = key_range
				break
			}

			existing_index := inline_find_key(current, key)
			if existing_index >= 0 {
				metadata := current.metadata[existing_index]
				if metadata.form == .Dotted_Table && metadata.child != nil {
					current = metadata.child
					release_owned_text(state, &key)
				} else {
					kind := Parse_Definition_Error_Kind.Non_Table_Path_Component
					if metadata.form == .Inline_Table {
						kind = .Inline_Table_Extended
					}
					if !inline_complete_diagnostic_path(state, index+1) {
						release_owned_text(state, &key)
						return {}, 0, false
					}
					container_store_error(
						state,
						inline_definition_error(
							state, kind, metadata.form, .Dotted_Table,
							key_range, metadata.range,
						),
					)
					release_owned_text(state, &key)
					return {}, 0, false
				}
			} else {
				empty_table: Table
				empty_table, ok = container_try_make_table(
					state, 0, key_range.start, key_range.end,
				)
				if !ok {
					release_owned_text(state, &key)
					return {}, 0, false
				}
				table_value := Value(empty_table)
				entry_index := len(current.table)
				child: ^Inline_Table_State
				child, ok = container_try_inline_child(
					state, current, entry_index, key_range.start, key_range.end,
				)
				if !ok {
					release_owned_text(state, &key)
					destroy_value_with_gate(&table_value, &state.gate, state.loc)
					return {}, 0, false
				}
				child.table = empty_table
				metadata := Inline_Entry_Metadata{
					form = .Dotted_Table,
					range = key_range,
					child = child,
				}
				if !container_try_inline_append(
					state, current, &key, &table_value, metadata,
					key_range.start, key_range.end,
				) {
					release_owned_text(state, &key)
					inline_cleanup_scratch(state, child)
					release_owned_memory(
						&state.gate, child, size_of(Inline_Table_State), state.loc,
					)
					destroy_value_with_gate(&table_value, &state.gate, state.loc)
					return {}, 0, false
				}
				current = child
			}
			index = skip_horizontal_whitespace(state.input, index+1)
		}

		if index >= len(state.input) || state.input[index] != '=' {
			container_fail_grammar(
				state, Parse_Syntax_Set{.Equals}, found_syntax_at(state.input, index),
				index, index,
			)
			return {}, 0, false
		}
		if existing_index := inline_find_key(current, leaf_key); existing_index >= 0 {
			metadata := current.metadata[existing_index]
			kind := Parse_Definition_Error_Kind.Duplicate_Key
			if metadata.form == .Dotted_Table {
				kind = .Dotted_Table_Redefined
			}
			container_store_error(
				state,
				inline_definition_error(
					state, kind, metadata.form, .Key_Value, leaf_range, metadata.range,
				),
			)
			return {}, 0, false
		}

		index = skip_horizontal_whitespace(state.input, index+1)
		if index >= len(state.input) || state.input[index] == '\n' || state.input[index] == '\r' ||
		   state.input[index] == '#' || state.input[index] == ',' || state.input[index] == '}' {
			container_fail_grammar(
				state, Parse_Syntax_Set{.Value}, found_syntax_at(state.input, index),
				index, index+min(1, len(state.input)-index),
			)
			return {}, 0, false
		}
		value: Value
		value_end: int
		form: Parse_Definition_Form
		value, value_end, form, ok = parser_parse_value(state, index, .Inline_Table)
		if !ok {
			return {}, 0, false
		}
		value_range_id := state.last_binding_range_id
		value_owned := true
		defer if value_owned {
			destroy_value_with_gate(&value, &state.gate, state.loc)
		}
		metadata := Inline_Entry_Metadata{
			form = form,
			range = {leaf_range.start, value_end},
		}
		leaf_entry_index := len(current.table)
		if !container_try_inline_append(
			state, current, &leaf_key, &value, metadata, pair_start, value_end,
		) {
			return {}, 0, false
		}
		parser_binding_range_attach(
			state,
			value_range_id,
			current.binding_range_id,
			leaf_entry_index,
		)
		parser_binding_range_set_key_source(
			state,
			value_range_id,
			leaf_range,
		)
		value_owned = false
		leaf_owned = false

		index, ok = container_try_trivia(state, value_end)
		if !ok {
			return {}, 0, false
		}
		if index < len(state.input) && state.input[index] == '}' {
			parser_path_pop_to(state, base_path_count)
			parser_binding_range_finish(state, root.binding_range_id, start, index+1)
			state.last_binding_range_id = root.binding_range_id
			owned = false
			return Value(root.table), index+1, true
		}
		if index >= len(state.input) || state.input[index] != ',' {
			container_fail_grammar(
				state, Parse_Syntax_Set{.Comma, .Right_Brace},
				found_syntax_at(state.input, index),
				index, index+min(1, len(state.input)-index),
			)
			return {}, 0, false
		}
		parser_path_pop_to(state, base_path_count)
		index, ok = container_try_trivia(state, index+1)
		if !ok {
			return {}, 0, false
		}
		if index < len(state.input) && state.input[index] == '}' {
			parser_binding_range_finish(state, root.binding_range_id, start, index+1)
			state.last_binding_range_id = root.binding_range_id
			owned = false
			return Value(root.table), index+1, true
		}
	}
}

@(private)
parser_parse_leaf_value :: proc(
	state: ^Parser_State,
	start: int,
	ctx: Parser_Value_Context,
) -> (value: Value, end: int, form: Parse_Definition_Form, ok: bool) {
	if start >= len(state.input) {
		container_fail_grammar(
			state, Parse_Syntax_Set{.Value}, .End_Of_Input, start, start,
		)
		return {}, 0, .Key_Value, false
	}
	character := state.input[start]
	if character == '"' || character == '\'' {
		kind := Quoted_Text_Kind.Basic
		if character == '\'' {
			kind = .Literal
		}
		if start+2 < len(state.input) && state.input[start+1] == character &&
		   state.input[start+2] == character {
			kind = .Multiline_Basic
			if character == '\'' {
				kind = .Multiline_Literal
			}
		}
		text: string
		err: Parse_Error
		text, end, err = parser_owned_text(
			state, start, kind, .Current,
		)
		if err != nil {
			container_store_error(state, err)
			return {}, 0, .Key_Value, false
		}
		if !parser_capture_value_range(state, start, end) {
			release_owned_text(state, &text)
			return {}, 0, .Key_Value, false
		}
		return Value(String(text)), end, .Key_Value, true
	}
	err: Parse_Error
	end, err = scan_scalar_candidate(
		state, start, .Current, ctx,
	)
	if err != nil {
		container_store_error(state, err)
		return {}, 0, .Key_Value, false
	}
	if end == start {
		container_store_error(
			state,
			parse_value_error(
				state, .Invalid_Value, start, start+1, .Current,
			),
		)
		return {}, 0, .Key_Value, false
	}
	value, err = parse_scalar_candidate(
		state, start, end, .Current,
	)
	if err != nil {
		container_store_error(state, err)
		return {}, 0, .Key_Value, false
	}
	if !parser_capture_value_range(state, start, end) {
		return {}, 0, .Key_Value, false
	}
	return value, end, .Key_Value, true
}

@(private)
parser_parse_value :: proc(
	state: ^Parser_State,
	start: int,
	ctx: Parser_Value_Context,
) -> (value: Value, end: int, form: Parse_Definition_Form, ok: bool) {
	if start < len(state.input) && state.input[start] == '[' {
		value, end, ok = parser_parse_array(state, start)
		return value, end, .Static_Array, ok
	}
	if start < len(state.input) && state.input[start] == '{' {
		value, end, ok = parser_parse_inline_table(state, start)
		return value, end, .Inline_Table, ok
	}
	return parser_parse_leaf_value(state, start, ctx)
}

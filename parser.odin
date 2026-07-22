package toml

import "base:runtime"
import "core:math/big"
import "core:mem"
import temporal "temporal"

parse :: proc {
	parse_bytes,
	parse_string,
}

@(private)
Parser_State :: struct {
	input:     string,
	allocator: runtime.Allocator,
	gate:      Allocator_Release_Gate,
	root:         Table,
	nodes:          Parser_Node_Array,
	binding_ranges: Binding_Range_Node_Array,
	capture_binding_ranges: bool,
	last_binding_range_id: int,
	active_table:   int,
	active_path:  Parser_Path_Stack,
	max_depth:      int,
	container_path:  Parser_Path_Stack,
	container_error: Parse_Error,
	loc:             runtime.Source_Code_Location,
}

@(private)
Parser_Diagnostic_Path :: enum u8 {
	Root,
	Current,
}

@(private)
Quoted_Text_Kind :: enum u8 {
	Basic,
	Literal,
	Multiline_Basic,
	Multiline_Literal,
}

@(private)
utf8_scalar_size_at :: proc(input: string, index: int) -> int {
	first := input[index]
	if first < 0x80 {
		return 1
	}
	if first < 0xe0 {
		return 2
	}
	if first < 0xf0 {
		return 3
	}
	return 4
}

@(private)
source_position_at :: proc(input: string, target: int) -> Source_Position {
	position := Source_Position{byte = 0, line = 1, column = 1}
	for position.byte < target {
		if input[position.byte] == '\r' && position.byte+1 < target &&
		   input[position.byte+1] == '\n' {
			position.byte += 2
			position.line += 1
			position.column = 1
			continue
		}
		if input[position.byte] == '\n' {
			position.byte += 1
			position.line += 1
			position.column = 1
			continue
		}
		position.byte += utf8_scalar_size_at(input, position.byte)
		position.column += 1
	}
	position.byte = target
	return position
}

@(private)
source_range :: proc(input: string, start, end: int) -> Source_Range {
	return {source_position_at(input, start), source_position_at(input, end)}
}

@(private)
parse_diagnostic :: proc(
	state: ^Parser_State,
	detail: Parse_Diagnostic_Detail,
	start, end: int,
	path: Parser_Diagnostic_Path = .Root,
	related: Optional_Source_Range = {},
) -> Parse_Error {
	resolved_path: Parse_Diagnostic_Path
	if path == .Current {
		resolved_path = parser_path_snapshot(state)
	}
	return Parse_Diagnostic{
		detail = detail,
		primary = source_range(state.input, start, end),
		related = related,
		path = resolved_path,
	}
}

@(private)
parse_lexical_error :: proc(
	state: ^Parser_State,
	kind: Parse_Lexical_Error,
	start, end: int,
	path: Parser_Diagnostic_Path = .Root,
) -> Parse_Error {
	return parse_diagnostic(
		state,
		Parse_Diagnostic_Detail(kind),
		start,
		end,
		path,
	)
}

@(private)
parse_value_error :: proc(
	state: ^Parser_State,
	kind: Parse_Value_Error_Kind,
	start, end: int,
	path: Parser_Diagnostic_Path,
	temporal_error: temporal.Error = .None,
) -> Parse_Error {
	return parse_diagnostic(
		state,
		Parse_Diagnostic_Detail(Parse_Value_Error{
			kind = kind,
			temporal_error = temporal_error,
		}),
		start,
		end,
		path,
	)
}

@(private)
parse_grammar_error :: proc(
	state: ^Parser_State,
	expected: Parse_Syntax_Set,
	found: Parse_Syntax,
	start, end: int,
	path: Parser_Diagnostic_Path = .Root,
) -> Parse_Error {
	return parse_diagnostic(
		state,
		Parse_Diagnostic_Detail(Parse_Grammar_Error{expected, found}),
		start,
		end,
		path,
	)
}

@(private)
parse_limit_error :: proc(
	state: ^Parser_State,
	kind: Parse_Limit_Error,
	start, end: int,
	path: Parser_Diagnostic_Path,
) -> Parse_Error {
	return parse_diagnostic(
		state,
		Parse_Diagnostic_Detail(kind),
		start,
		end,
		path,
	)
}

@(private)
first_invalid_utf8_byte :: proc(input: string) -> (int, bool) {
	for index := 0; index < len(input); {
		first := input[index]
		if first < 0x80 {
			index += 1
			continue
		}
		if 0xc2 <= first && first <= 0xdf {
			if index+1 >= len(input) || input[index+1]&0xc0 != 0x80 {
				return index, true
			}
			index += 2
			continue
		}
		if first == 0xe0 {
			if index+2 >= len(input) || input[index+1] < 0xa0 || input[index+1] > 0xbf ||
			   input[index+2]&0xc0 != 0x80 {
				return index, true
			}
			index += 3
			continue
		}
		if (0xe1 <= first && first <= 0xec) || (0xee <= first && first <= 0xef) {
			if index+2 >= len(input) || input[index+1]&0xc0 != 0x80 ||
			   input[index+2]&0xc0 != 0x80 {
				return index, true
			}
			index += 3
			continue
		}
		if first == 0xed {
			if index+2 >= len(input) || input[index+1] < 0x80 || input[index+1] > 0x9f ||
			   input[index+2]&0xc0 != 0x80 {
				return index, true
			}
			index += 3
			continue
		}
		if first == 0xf0 {
			if index+3 >= len(input) || input[index+1] < 0x90 || input[index+1] > 0xbf ||
			   input[index+2]&0xc0 != 0x80 || input[index+3]&0xc0 != 0x80 {
				return index, true
			}
			index += 4
			continue
		}
		if 0xf1 <= first && first <= 0xf3 {
			if index+3 >= len(input) || input[index+1]&0xc0 != 0x80 ||
			   input[index+2]&0xc0 != 0x80 || input[index+3]&0xc0 != 0x80 {
				return index, true
			}
			index += 4
			continue
		}
		if first == 0xf4 {
			if index+3 >= len(input) || input[index+1] < 0x80 || input[index+1] > 0x8f ||
			   input[index+2]&0xc0 != 0x80 || input[index+3]&0xc0 != 0x80 {
				return index, true
			}
			index += 4
			continue
		}
		return index, true
	}
	return 0, false
}

@(private)
utf8_encoding_diagnostic :: proc(input: string, invalid: int) -> Parse_Error {
	position := source_position_at(input, invalid)
	end := position
	end.byte += 1
	diagnostic: Parse_Diagnostic
	diagnostic.detail = Parse_Encoding_Error.Invalid_UTF8
	diagnostic.primary = {position, end}
	return diagnostic
}

@(private)
is_bare_key_byte :: proc(value: byte) -> bool {
	return 'a' <= value && value <= 'z' || 'A' <= value && value <= 'Z' ||
	       '0' <= value && value <= '9' || value == '_' || value == '-'
}

@(private)
is_hex_digit :: proc(value: byte) -> bool {
	return '0' <= value && value <= '9' || 'a' <= value && value <= 'f' ||
	       'A' <= value && value <= 'F'
}

@(private)
hex_digit_value :: proc(value: byte) -> u32 {
	if '0' <= value && value <= '9' {
		return u32(value-'0')
	}
	if 'a' <= value && value <= 'f' {
		return u32(value-'a'+10)
	}
	return u32(value-'A'+10)
}

@(private)
Quoted_Text_Output :: struct {
	bytes: []byte,
	start: int,
}

@(private)
emit_byte :: proc(output: Quoted_Text_Output, output_index: ^int, value: byte) {
	if output.bytes != nil && output.start <= output_index^ &&
	   output_index^-output.start < len(output.bytes) {
		output.bytes[output_index^-output.start] = value
	}
	output_index^ += 1
}

@(private)
emit_bytes :: proc(
	output: Quoted_Text_Output,
	output_index: ^int,
	input: string,
	start, count: int,
) {
	if output.bytes != nil {
		capture_start := max(output_index^, output.start)
		capture_end := min(output_index^+count, output.start+len(output.bytes))
		if capture_start < capture_end {
			input_offset := capture_start-output_index^
			output_offset := capture_start-output.start
			copy(
				output.bytes[output_offset:output_offset+capture_end-capture_start],
				transmute([]byte)input[start+input_offset:start+input_offset+capture_end-capture_start],
			)
		}
	}
	output_index^ += count
}

@(private)
emit_scalar :: proc(output: Quoted_Text_Output, output_index: ^int, scalar: u32) {
	if scalar <= 0x7f {
		emit_byte(output, output_index, byte(scalar))
	} else if scalar <= 0x7ff {
		emit_byte(output, output_index, byte(0xc0 | scalar>>6))
		emit_byte(output, output_index, byte(0x80 | scalar&0x3f))
	} else if scalar <= 0xffff {
		emit_byte(output, output_index, byte(0xe0 | scalar>>12))
		emit_byte(output, output_index, byte(0x80 | scalar>>6&0x3f))
		emit_byte(output, output_index, byte(0x80 | scalar&0x3f))
	} else {
		emit_byte(output, output_index, byte(0xf0 | scalar>>18))
		emit_byte(output, output_index, byte(0x80 | scalar>>12&0x3f))
		emit_byte(output, output_index, byte(0x80 | scalar>>6&0x3f))
		emit_byte(output, output_index, byte(0x80 | scalar&0x3f))
	}
}

@(private)
emit_normalized_newline :: proc(output: Quoted_Text_Output, output_index: ^int) {
	when ODIN_OS == .Windows {
		emit_byte(output, output_index, '\r')
		emit_byte(output, output_index, '\n')
	} else {
		emit_byte(output, output_index, '\n')
	}
}

@(private)
quoted_text_scan :: proc(
	state: ^Parser_State,
	start: int,
	kind: Quoted_Text_Kind,
	output: Quoted_Text_Output,
	path: Parser_Diagnostic_Path,
) -> (end, output_count: int, err: Parse_Error) {
	multiline := kind == .Multiline_Basic || kind == .Multiline_Literal
	basic := kind == .Basic || kind == .Multiline_Basic
	quote := byte('"') if basic else byte('\'')
	delimiter_size := 3 if multiline else 1
	index := start+delimiter_size

	if multiline {
		if index < len(state.input) && state.input[index] == '\n' {
			index += 1
		} else if index+1 < len(state.input) && state.input[index] == '\r' &&
		          state.input[index+1] == '\n' {
			index += 2
		}
	}

	for index < len(state.input) {
		character := state.input[index]
		if character == quote {
			run_end := index+1
			for run_end < len(state.input) && state.input[run_end] == quote {
				run_end += 1
			}
			run_length := run_end-index
			if !multiline {
				return index+1, output_count, nil
			}
			if run_length >= 3 {
				if run_length > 5 {
					return 0, 0, parse_lexical_error(
						state,
						.Invalid_String_Character,
						index,
						run_end,
						path,
					)
				}
				for _ in 0..<run_length-3 {
					emit_byte(output, &output_count, quote)
				}
				return run_end, output_count, nil
			}
			for _ in 0..<run_length {
				emit_byte(output, &output_count, quote)
			}
			index = run_end
			continue
		}

		if character == '\r' {
			if index+1 >= len(state.input) || state.input[index+1] != '\n' {
				return 0, 0, parse_lexical_error(state, .Invalid_Newline, index, index+1, path)
			}
			if !multiline {
				return 0, 0, parse_lexical_error(
					state,
					.Invalid_String_Character,
					index,
					index+2,
					path,
				)
			}
			emit_normalized_newline(output, &output_count)
			index += 2
			continue
		}
		if character == '\n' {
			if !multiline {
				return 0, 0, parse_lexical_error(
					state,
					.Invalid_String_Character,
					index,
					index+1,
					path,
				)
			}
			emit_normalized_newline(output, &output_count)
			index += 1
			continue
		}
		if character < 0x20 && character != '\t' || character == 0x7f {
			return 0, 0, parse_lexical_error(
				state,
				.Invalid_String_Character,
				index,
				index+1,
				path,
			)
		}

		if basic && character == '\\' {
			escape_start := index
			index += 1
			if index >= len(state.input) {
				return 0, 0, parse_lexical_error(
					state,
					.Invalid_Escape,
					escape_start,
					index,
					path,
				)
			}

			if multiline {
				fold := index
				for fold < len(state.input) &&
				    (state.input[fold] == ' ' || state.input[fold] == '\t') {
					fold += 1
				}
				newline_end := fold
				if fold < len(state.input) && state.input[fold] == '\n' {
					newline_end = fold+1
				} else if fold+1 < len(state.input) && state.input[fold] == '\r' &&
				          state.input[fold+1] == '\n' {
					newline_end = fold+2
				}
				if newline_end != fold {
					index = newline_end
					for index < len(state.input) {
						if state.input[index] == ' ' || state.input[index] == '\t' {
							index += 1
							continue
						}
						if state.input[index] == '\n' {
							index += 1
							continue
						}
						if index+1 < len(state.input) && state.input[index] == '\r' &&
						   state.input[index+1] == '\n' {
							index += 2
							continue
						}
						break
					}
					continue
				}
			}

			escape := state.input[index]
			switch escape {
			case 'b':
				emit_byte(output, &output_count, '\b')
				index += 1
			case 't':
				emit_byte(output, &output_count, '\t')
				index += 1
			case 'n':
				emit_byte(output, &output_count, '\n')
				index += 1
			case 'f':
				emit_byte(output, &output_count, '\f')
				index += 1
			case 'r':
				emit_byte(output, &output_count, '\r')
				index += 1
			case 'e':
				emit_byte(output, &output_count, 0x1b)
				index += 1
			case '"':
				emit_byte(output, &output_count, '"')
				index += 1
			case '\\':
				emit_byte(output, &output_count, '\\')
				index += 1
			case 'x', 'u', 'U':
				digit_count := 2
				if escape == 'u' {
					digit_count = 4
				} else if escape == 'U' {
					digit_count = 8
				}
				digit_start := index+1
				digit_end := digit_start+digit_count
				if digit_end > len(state.input) {
					return 0, 0, parse_lexical_error(
						state,
						.Invalid_Unicode_Escape,
						escape_start,
						len(state.input),
						path,
					)
				}
				scalar := u32(0)
				for digit_index in digit_start..<digit_end {
					if !is_hex_digit(state.input[digit_index]) {
						return 0, 0, parse_lexical_error(
							state,
							.Invalid_Unicode_Escape,
							digit_index,
							digit_index+1,
							path,
						)
					}
					scalar = scalar<<4 | hex_digit_value(state.input[digit_index])
				}
				if scalar > 0x10ffff || 0xd800 <= scalar && scalar <= 0xdfff {
					return 0, 0, parse_lexical_error(
						state,
						.Invalid_Unicode_Escape,
						escape_start,
						digit_end,
						path,
					)
				}
				emit_scalar(output, &output_count, scalar)
				index = digit_end
			case:
				return 0, 0, parse_lexical_error(
					state,
					.Invalid_Escape,
					escape_start,
					index+utf8_scalar_size_at(state.input, index),
					path,
				)
			}
			continue
		}

		scalar_size := utf8_scalar_size_at(state.input, index)
		emit_bytes(output, &output_count, state.input, index, scalar_size)
		index += scalar_size
	}

	unterminated := Parse_Lexical_Error.Unterminated_Literal_String
	if basic {
		unterminated = .Unterminated_Basic_String
	}
	return 0, 0, parse_lexical_error(state, unterminated, start, len(state.input), path)
}

@(private)
parser_owned_text :: proc(
	state: ^Parser_State,
	start: int,
	kind: Quoted_Text_Kind,
	path: Parser_Diagnostic_Path,
) -> (text: string, end: int, err: Parse_Error) {
	count: int
	end, count, err = quoted_text_scan(state, start, kind, {}, path)
	if err != nil {
		return "", 0, err
	}
	if count == 0 {
		return "", end, nil
	}
	memory, allocation_error := allocator_allocate(count, state.allocator, false, state.loc)
	if allocation_error != nil {
		return "", 0, allocation_error
	}
	if memory == nil {
		return "", 0, runtime.Allocator_Error.Out_Of_Memory
	}
	bytes := mem.byte_slice(memory, count)
	second_end, second_count, second_error := quoted_text_scan(
		state, start, kind, Quoted_Text_Output{bytes = bytes}, path,
	)
	if second_error != nil || second_end != end || second_count != count {
		release_owned_memory(&state.gate, memory, count, state.loc)
		unreachable()
	}
	return string(bytes), end, nil
}

@(private)
parser_clone_source_text :: proc(
	state: ^Parser_State,
	start, end: int,
) -> (string, Parse_Error) {
	count := end-start
	if count == 0 {
		return "", nil
	}
	memory, allocation_error := allocator_allocate(count, state.allocator, false, state.loc)
	if allocation_error != nil {
		return "", allocation_error
	}
	if memory == nil {
		return "", runtime.Allocator_Error.Out_Of_Memory
	}
	mem.copy_non_overlapping(memory, raw_data(state.input[start:end]), count)
	return string(mem.byte_slice(memory, count)), nil
}

@(private)
utf8_prefix_length :: proc(text: string, maximum: int) -> int {
	if len(text) <= maximum {
		return len(text)
	}
	end := maximum
	for end > 0 && text[end]&0xc0 == 0x80 {
		end -= 1
	}
	return end
}

@(private)
utf8_suffix_start :: proc(text: string, minimum: int) -> int {
	start := minimum
	for start < len(text) && text[start]&0xc0 == 0x80 {
		start += 1
	}
	return start
}

@(private)
parse_path_segment_for_key :: proc(
	key: string,
	key_source: Source_Byte_Range,
) -> Parse_Diagnostic_Path_Segment {
	key_snapshot := Parse_Diagnostic_Key{
		decoded_byte_length = len(key),
		source = key_source,
	}
	if len(key) <= PARSE_DIAGNOSTIC_KEY_CAPACITY {
		copy(key_snapshot.bytes[:], transmute([]byte)key)
		key_snapshot.prefix_length = u8(len(key))
	} else {
		prefix_length := utf8_prefix_length(key, PARSE_DIAGNOSTIC_KEY_PREFIX_BYTES)
		suffix_start := utf8_suffix_start(
			key,
			len(key)-(PARSE_DIAGNOSTIC_KEY_CAPACITY-PARSE_DIAGNOSTIC_KEY_PREFIX_BYTES),
		)
		suffix_length := len(key)-suffix_start
		copy(key_snapshot.bytes[:prefix_length], transmute([]byte)key[:prefix_length])
		copy(
			key_snapshot.bytes[prefix_length:prefix_length+suffix_length],
			transmute([]byte)key[suffix_start:],
		)
		key_snapshot.prefix_length = u8(prefix_length)
		key_snapshot.suffix_length = u8(suffix_length)
		key_snapshot.omitted_byte_count = len(key)-prefix_length-suffix_length
		key_snapshot.truncated = true
	}
	return Parse_Diagnostic_Path_Segment(key_snapshot)
}

@(private)
parse_path_segment_for_source :: proc(
	state: ^Parser_State,
	key_source: Source_Byte_Range,
) -> Parse_Diagnostic_Path_Segment {
	assert(0 <= key_source.start && key_source.start < key_source.end)
	assert(key_source.end <= len(state.input))
	character := state.input[key_source.start]
	if character != '"' && character != '\'' {
		return parse_path_segment_for_key(
			state.input[key_source.start:key_source.end], key_source,
		)
	}

	kind := Quoted_Text_Kind.Basic
	if character == '\'' {
		kind = .Literal
	}
	decoded_count, end: int
	err: Parse_Error
	end, decoded_count, err = quoted_text_scan(
		state, key_source.start, kind, {}, .Root,
	)
	assert(err == nil && end == key_source.end)
	key_snapshot := Parse_Diagnostic_Key{
		decoded_byte_length = decoded_count,
		source = key_source,
	}
	if decoded_count <= PARSE_DIAGNOSTIC_KEY_CAPACITY {
		decoded: [PARSE_DIAGNOSTIC_KEY_CAPACITY]byte
		second_end, second_count, second_error := quoted_text_scan(
			state,
			key_source.start,
			kind,
			Quoted_Text_Output{bytes = decoded[:decoded_count]},
			.Root,
		)
		assert(second_error == nil && second_end == end && second_count == decoded_count)
		copy(key_snapshot.bytes[:decoded_count], decoded[:decoded_count])
		key_snapshot.prefix_length = u8(decoded_count)
	} else {
		// Four-byte UTF-8 scalars need at most three bytes beyond either
		// 32-byte diagnostic boundary to find the longest complete prefix/suffix.
		DIAGNOSTIC_WINDOW :: PARSE_DIAGNOSTIC_KEY_PREFIX_BYTES+3
		prefix: [DIAGNOSTIC_WINDOW]byte
		suffix: [DIAGNOSTIC_WINDOW]byte
		prefix_end, prefix_count, prefix_error := quoted_text_scan(
			state,
			key_source.start,
			kind,
			Quoted_Text_Output{bytes = prefix[:]},
			.Root,
		)
		suffix_end, suffix_count, suffix_error := quoted_text_scan(
			state,
			key_source.start,
			kind,
			Quoted_Text_Output{
				bytes = suffix[:],
				start = decoded_count-DIAGNOSTIC_WINDOW,
			},
			.Root,
		)
		assert(prefix_error == nil && suffix_error == nil)
		assert(prefix_end == end && suffix_end == end)
		assert(prefix_count == decoded_count && suffix_count == decoded_count)
		prefix_length := utf8_prefix_length(
			string(prefix[:]), PARSE_DIAGNOSTIC_KEY_PREFIX_BYTES,
		)
		suffix_start := utf8_suffix_start(
			string(suffix[:]),
			DIAGNOSTIC_WINDOW-(
				PARSE_DIAGNOSTIC_KEY_CAPACITY-PARSE_DIAGNOSTIC_KEY_PREFIX_BYTES
			),
		)
		suffix_length := DIAGNOSTIC_WINDOW-suffix_start
		copy(key_snapshot.bytes[:prefix_length], prefix[:prefix_length])
		copy(
			key_snapshot.bytes[prefix_length:prefix_length+suffix_length],
			suffix[suffix_start:],
		)
		key_snapshot.prefix_length = u8(prefix_length)
		key_snapshot.suffix_length = u8(suffix_length)
		key_snapshot.omitted_byte_count = decoded_count-prefix_length-suffix_length
		key_snapshot.truncated = true
	}
	return Parse_Diagnostic_Path_Segment(key_snapshot)
}

@(private)
parse_simple_key :: proc(
	state: ^Parser_State,
	start: int,
	path: Parser_Diagnostic_Path = .Root,
) -> (key: string, end: int, key_range: Source_Byte_Range, err: Parse_Error) {
	if start >= len(state.input) {
		return "", 0, {}, parse_grammar_error(
			state,
			Parse_Syntax_Set{.Key},
			.End_Of_Input,
			start,
			start,
			path,
		)
	}
	character := state.input[start]
	if character == '"' || character == '\'' {
		if start+2 < len(state.input) && state.input[start+1] == character &&
		   state.input[start+2] == character {
			return "", 0, {}, parse_lexical_error(
				state,
				.Invalid_Bare_Key,
				start,
				start+3,
				path,
			)
		}
		kind := Quoted_Text_Kind.Basic
		if character == '\'' {
			kind = .Literal
		}
		key, end, err = parser_owned_text(state, start, kind, path)
		if err != nil {
			return "", 0, {}, err
		}
		return key, end, {start, end}, nil
	}
	if !is_bare_key_byte(character) {
		scalar_end := start+utf8_scalar_size_at(state.input, start)
		return "", 0, {}, parse_lexical_error(
			state,
			.Invalid_Bare_Key,
			start,
			scalar_end,
			path,
		)
	}
	end = start+1
	for end < len(state.input) && is_bare_key_byte(state.input[end]) {
		end += 1
	}
	key, err = parser_clone_source_text(state, start, end)
	if err != nil {
		return "", 0, {}, err
	}
	return key, end, {start, end}, nil
}

@(private)
release_owned_text :: proc(state: ^Parser_State, text: ^string) {
	if text == nil {
		return
	}
	release_owned_memory(&state.gate, raw_data(text^), len(text^), state.loc)
	text^ = ""
}

@(private)
parser_growth_capacity :: proc(
	current, required, element_size: int,
) -> (capacity: int, ok: bool) {
	if current < 0 || required < 0 || element_size <= 0 {
		return 0, false
	}
	maximum := max(int)/element_size
	if required > maximum {
		return 0, false
	}
	capacity = max(1, current)
	for capacity < required {
		if capacity > maximum/2 {
			capacity = maximum
		} else {
			capacity *= 2
		}
	}
	return capacity, true
}

@(private)
parser_make_table_capacity :: proc(
	state: ^Parser_State,
	count, capacity: int,
	start, end: int,
	path: Parser_Diagnostic_Path,
) -> (Table, Parse_Error) {
	if count < 0 || capacity < count || capacity > max(int)/size_of(Entry) {
		return {}, parse_limit_error(state, .Size_Overflow, start, end, path)
	}
	memory: rawptr
	if capacity > 0 {
		allocation_error: runtime.Allocator_Error
		memory, allocation_error = allocator_allocate(
			capacity*size_of(Entry),
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
	return transmute(Table)raw, nil
}

@(private)
parser_make_table :: proc(
	state: ^Parser_State,
	count: int,
	start, end: int,
	path: Parser_Diagnostic_Path,
) -> (Table, Parse_Error) {
	return parser_make_table_capacity(state, count, count, start, end, path)
}

@(private)
is_decimal_digit :: proc(value: byte) -> bool {
	return '0' <= value && value <= '9'
}

@(private)
has_date_prefix :: proc(text: string) -> bool {
	return len(text) >= 10 && is_decimal_digit(text[0]) && is_decimal_digit(text[1]) &&
	       is_decimal_digit(text[2]) && is_decimal_digit(text[3]) && text[4] == '-' &&
	       is_decimal_digit(text[5]) && is_decimal_digit(text[6]) && text[7] == '-' &&
	       is_decimal_digit(text[8]) && is_decimal_digit(text[9])
}

@(private)
has_time_prefix :: proc(text: string) -> bool {
	return len(text) >= 5 && is_decimal_digit(text[0]) && is_decimal_digit(text[1]) &&
	       text[2] == ':' && is_decimal_digit(text[3]) && is_decimal_digit(text[4])
}

@(private)
string_has_prefix :: proc(text, prefix: string) -> bool {
	return len(text) >= len(prefix) && text[:len(prefix)] == prefix
}

@(private)
scan_scalar_candidate :: proc(
	state: ^Parser_State,
	start: int,
	path: Parser_Diagnostic_Path,
	ctx: Parser_Value_Context = .Document,
) -> (int, Parse_Error) {
	index := start
	date_candidate := has_date_prefix(state.input[start:])
	for index < len(state.input) {
		character := state.input[index]
		if character == ' ' {
			if date_candidate && index == start+10 && index+6 <= len(state.input) &&
			   has_time_prefix(state.input[index+1:]) {
				index += 1
				continue
			}
			break
		}
		if character == '\t' || character == '\n' || character == '#' ||
		   ctx == .Array && (character == ',' || character == ']') ||
		   ctx == .Inline_Table && (character == ',' || character == '}') {
			break
		}
		if character == '\r' {
			if index+1 < len(state.input) && state.input[index+1] == '\n' {
				break
			}
			return 0, parse_lexical_error(state, .Invalid_Newline, index, index+1, path)
		}
		if character < 0x20 || character == 0x7f || character >= 0x80 {
			return 0, parse_lexical_error(
				state,
				.Illegal_Character,
				index,
				index+utf8_scalar_size_at(state.input, index),
				path,
			)
		}
		index += 1
	}
	return index, nil
}

@(private)
parse_unsigned_digits :: proc(text: string, start, count: int) -> (u32, bool) {
	if start < 0 || count < 0 || start+count > len(text) {
		return 0, false
	}
	value := u32(0)
	for index in start..<start+count {
		if !is_decimal_digit(text[index]) {
			return 0, false
		}
		value = value*10+u32(text[index]-'0')
	}
	return value, true
}

@(private)
parse_temporal_candidate :: proc(text: string) -> (Value, temporal.Error, bool) {
	date: temporal.Local_Date
	time: temporal.Local_Time
	index := 0
	has_date := has_date_prefix(text)
	if has_date {
		year, year_ok := parse_unsigned_digits(text, 0, 4)
		month, month_ok := parse_unsigned_digits(text, 5, 2)
		day, day_ok := parse_unsigned_digits(text, 8, 2)
		if !year_ok || !month_ok || !day_ok {
			return {}, .None, false
		}
		date = {u16(year), u8(month), u8(day)}
		if date_error := temporal.validate_local_date(date); date_error != .None {
			return {}, date_error, false
		}
		index = 10
		if index == len(text) {
			return Value(date), .None, true
		}
		if text[index] != 'T' && text[index] != 't' && text[index] != ' ' {
			return {}, .None, false
		}
		index += 1
	} else if !has_time_prefix(text) {
		return {}, .None, false
	}

	if index+5 > len(text) || text[index+2] != ':' {
		return {}, .None, false
	}
	hour, hour_ok := parse_unsigned_digits(text, index, 2)
	minute, minute_ok := parse_unsigned_digits(text, index+3, 2)
	if !hour_ok || !minute_ok {
		return {}, .None, false
	}
	time.hour = u8(hour)
	time.minute = u8(minute)
	index += 5
	has_seconds := false
	if index < len(text) && text[index] == ':' {
		second, second_ok := parse_unsigned_digits(text, index+1, 2)
		if !second_ok {
			return {}, .None, false
		}
		time.second = u8(second)
		has_seconds = true
		index += 3
	}
	if index < len(text) && text[index] == '.' {
		if !has_seconds {
			return {}, .None, false
		}
		index += 1
		fraction_start := index
		nanosecond := u32(0)
		digit_count := 0
		for index < len(text) && is_decimal_digit(text[index]) {
			if digit_count < 9 {
				nanosecond = nanosecond*10+u32(text[index]-'0')
			}
			digit_count += 1
			index += 1
		}
		if index == fraction_start {
			return {}, .None, false
		}
		for digit_count < 9 {
			nanosecond *= 10
			digit_count += 1
		}
		time.nanosecond = nanosecond
	}
	if time_error := temporal.validate_local_time(time); time_error != .None {
		return {}, time_error, false
	}
	if !has_date {
		if index != len(text) {
			return {}, .None, false
		}
		return Value(time), .None, true
	}
	local := temporal.Local_Date_Time{date, time}
	if index == len(text) {
		return Value(local), .None, true
	}

	offset := temporal.UTC_Offset{kind = .Known}
	if text[index] == 'Z' || text[index] == 'z' {
		index += 1
	} else if text[index] == '+' || text[index] == '-' {
		negative := text[index] == '-'
		if index+6 > len(text) || text[index+3] != ':' {
			return {}, .None, false
		}
		offset_hour, offset_hour_ok := parse_unsigned_digits(text, index+1, 2)
		offset_minute, offset_minute_ok := parse_unsigned_digits(text, index+4, 2)
		if !offset_hour_ok || !offset_minute_ok {
			return {}, .None, false
		}
		if offset_hour > 23 || offset_minute > 59 {
			return {}, .Invalid_Offset_Minutes, false
		}
		magnitude := int(offset_hour)*60+int(offset_minute)
		if negative && magnitude == 0 {
			offset.kind = .Unknown
			offset.minutes = 0
		} else {
			if negative {
				magnitude = -magnitude
			}
			offset.minutes = i16(magnitude)
		}
		index += 6
	} else {
		return {}, .None, false
	}
	if index != len(text) {
		return {}, .None, false
	}
	if offset_error := temporal.validate_utc_offset(offset); offset_error != .None {
		return {}, offset_error, false
	}
	return Value(temporal.Offset_Date_Time{local, offset}), .None, true
}

@(private)
integer_digit_value :: proc(value: byte) -> (u64, bool) {
	if '0' <= value && value <= '9' {
		return u64(value-'0'), true
	}
	if 'a' <= value && value <= 'f' {
		return u64(value-'a'+10), true
	}
	if 'A' <= value && value <= 'F' {
		return u64(value-'A'+10), true
	}
	return 0, false
}

@(private)
parse_integer_candidate :: proc(text: string) -> (
	value: Integer,
	error_kind: Parse_Value_Error_Kind,
	error_start, error_end: int,
	ok: bool,
) {
	error_kind = .Invalid_Integer
	if len(text) == 0 {
		return 0, error_kind, 0, 0, false
	}
	index := 0
	negative := false
	if text[index] == '+' || text[index] == '-' {
		negative = text[index] == '-'
		index += 1
		if index == len(text) {
			return 0, error_kind, index, index, false
		}
	}
	radix := u64(10)
	radix_form := false
	if index+1 < len(text) && text[index] == '0' {
		switch text[index+1] {
		case 'x':
			radix, radix_form = 16, true
		case 'o':
			radix, radix_form = 8, true
		case 'b':
			radix, radix_form = 2, true
		}
		if radix_form {
			if index > 0 {
				return 0, error_kind, 0, 1, false
			}
			index += 2
		}
	}
	if index == len(text) {
		return 0, error_kind, index, index, false
	}
	magnitude := u64(0)
	digit_count := 0
	previous_digit := false
	first_digit := byte(0)
	second_digit_index := -1
	limit := u64(max(i64))
	if negative {
		limit += 1
	}
	for index < len(text) {
		character := text[index]
		if character == '_' {
			next_digit_ok := false
			if index+1 < len(text) {
				next_digit, valid_digit := integer_digit_value(text[index+1])
				next_digit_ok = valid_digit && next_digit < radix
			}
			if !previous_digit || !next_digit_ok {
				return 0, error_kind, index, index+1, false
			}
			previous_digit = false
			index += 1
			continue
		}
		digit, digit_ok := integer_digit_value(character)
		if !digit_ok || digit >= radix {
			return 0, error_kind, index, index+1, false
		}
		if digit_count == 0 {
			first_digit = character
		} else if digit_count == 1 {
			second_digit_index = index
		}
		digit_count += 1
		previous_digit = true
		if magnitude > (limit-digit)/radix {
			return 0, .Integer_Out_Of_Range, 0, len(text), false
		}
		magnitude = magnitude*radix+digit
		index += 1
	}
	if !previous_digit || digit_count == 0 {
		return 0, error_kind, index, index, false
	}
	if !radix_form && digit_count > 1 && first_digit == '0' {
		return 0, error_kind, second_digit_index, second_digit_index+1, false
	}
	if negative {
		if magnitude == u64(max(i64))+1 {
			return Integer(min(i64)), error_kind, 0, 0, true
		}
		return Integer(-i64(magnitude)), error_kind, 0, 0, true
	}
	return Integer(magnitude), error_kind, 0, 0, true
}

@(private)
validate_decimal_float_syntax :: proc(text: string) -> (
	valid: bool,
	error_start, error_end: int,
) {
	if len(text) == 0 {
		return false, 0, 0
	}
	index := 0
	if text[index] == '+' || text[index] == '-' {
		index += 1
		if index == len(text) {
			return false, index, index
		}
	}
	integer_digits := 0
	previous_digit := false
	first_digit := byte(0)
	second_digit_index := -1
	for index < len(text) {
		if is_decimal_digit(text[index]) {
			if integer_digits == 0 {
				first_digit = text[index]
			} else if integer_digits == 1 {
				second_digit_index = index
			}
			integer_digits += 1
			previous_digit = true
			index += 1
			continue
		}
		if text[index] == '_' {
			if !previous_digit || index+1 >= len(text) ||
			   !is_decimal_digit(text[index+1]) {
				return false, index, index+1
			}
			previous_digit = false
			index += 1
			continue
		}
		break
	}
	if integer_digits == 0 {
		if index == len(text) {
			return false, index, index
		}
		return false, index, index+1
	}
	if integer_digits > 1 && first_digit == '0' {
		return false, second_digit_index, second_digit_index+1
	}
	saw_fraction := false
	if index < len(text) && text[index] == '.' {
		saw_fraction = true
		index += 1
		fraction_digits := 0
		previous_digit = false
		for index < len(text) {
			if is_decimal_digit(text[index]) {
				fraction_digits += 1
				previous_digit = true
				index += 1
				continue
			}
			if text[index] == '_' {
				if !previous_digit || index+1 >= len(text) ||
				   !is_decimal_digit(text[index+1]) {
					return false, index, index+1
				}
				previous_digit = false
				index += 1
				continue
			}
			break
		}
		if fraction_digits == 0 {
			if index == len(text) {
				return false, index, index
			}
			return false, index, index+1
		}
	}
	saw_exponent := false
	if index < len(text) && (text[index] == 'e' || text[index] == 'E') {
		saw_exponent = true
		index += 1
		if index < len(text) && (text[index] == '+' || text[index] == '-') {
			index += 1
		}
		exponent_digits := 0
		previous_digit = false
		for index < len(text) {
			if is_decimal_digit(text[index]) {
				exponent_digits += 1
				previous_digit = true
				index += 1
				continue
			}
			if text[index] == '_' {
				if !previous_digit || index+1 >= len(text) ||
				   !is_decimal_digit(text[index+1]) {
					return false, index, index+1
				}
				previous_digit = false
				index += 1
				continue
			}
			break
		}
		if exponent_digits == 0 {
			if index == len(text) {
				return false, index, index
			}
			return false, index, index+1
		}
	}
	if index != len(text) {
		return false, index, index+1
	}
	return saw_fraction || saw_exponent, 0, 0
}

@(private)
big_error_is_allocator_error :: proc(err: big.Error) -> bool {
	return err == .Out_Of_Memory || err == .Invalid_Pointer ||
	       err == .Invalid_Argument || err == .Mode_Not_Implemented
}

@(private)
parse_scalar_candidate :: proc(
	state: ^Parser_State,
	start, end: int,
	path: Parser_Diagnostic_Path,
) -> (Value, Parse_Error) {
	text := state.input[start:end]
	if string_has_prefix(text, "true") || string_has_prefix(text, "false") {
		if text == "true" {
			return Value(Boolean(true)), nil
		}
		if text == "false" {
			return Value(Boolean(false)), nil
		}
		valid_length := 4
		if string_has_prefix(text, "false") {
			valid_length = 5
		}
		return {}, parse_value_error(
			state,
			.Invalid_Boolean,
			start+valid_length,
			start+valid_length+1,
			path,
		)
	}
	if has_date_prefix(text) || has_time_prefix(text) {
		value, temporal_error, ok := parse_temporal_candidate(text)
		if ok {
			return value, nil
		}
		return {}, parse_value_error(
			state,
			.Invalid_Temporal,
			start,
			end,
			path,
			temporal_error,
		)
	}

	sign_offset := 0
	if len(text) > 0 && (text[0] == '+' || text[0] == '-') {
		sign_offset = 1
	}
	radix_candidate := len(text) >= sign_offset+2 && text[sign_offset] == '0' &&
	                  (text[sign_offset+1] == 'x' || text[sign_offset+1] == 'o' ||
	                   text[sign_offset+1] == 'b')
	if radix_candidate {
		integer, error_kind, error_start, error_end, ok := parse_integer_candidate(text)
		if ok {
			return Value(integer), nil
		}
		return {}, parse_value_error(
			state,
			error_kind,
			start+error_start,
			start+error_end,
			path,
		)
	}

	float_special_candidate := false
	if sign_offset < len(text) {
		remaining := text[sign_offset:]
		float_special_candidate = string_has_prefix(remaining, "inf") ||
		                          string_has_prefix(remaining, "nan")
	}
	contains_float_marker := false
	for character in text {
		if character == '.' || character == 'e' || character == 'E' {
			contains_float_marker = true
			break
		}
	}
	numeric_candidate := len(text) > 0 &&
	                     (text[0] == '+' || text[0] == '-' || is_decimal_digit(text[0]))
	if float_special_candidate || numeric_candidate && contains_float_marker {
		if text == "inf" || text == "+inf" {
			return Value(Float(transmute(f64)u64(0x7ff0_0000_0000_0000))), nil
		}
		if text == "-inf" {
			return Value(Float(transmute(f64)u64(0xfff0_0000_0000_0000))), nil
		}
		if text == "nan" || text == "+nan" || text == "-nan" {
			return Value(Float(transmute(f64)u64(0x7ff8_0000_0000_0000))), nil
		}
		if float_special_candidate {
			prefix_end := sign_offset+3
			return {}, parse_value_error(
				state,
				.Invalid_Float,
				start+prefix_end,
				start+prefix_end+1,
				path,
			)
		}
		valid_syntax, error_start, error_end := validate_decimal_float_syntax(text)
		if !valid_syntax {
			return {}, parse_value_error(
				state,
				.Invalid_Float,
				start+error_start,
				start+error_end,
				path,
			)
		}
		individually_release := state.gate.mode != .Logical
		float, status, conversion_error := decimal_to_binary64(
			text,
			state.allocator,
			individually_release,
		)
		if conversion_error != .None {
			if big_error_is_allocator_error(conversion_error) {
				return {}, runtime.Allocator_Error(conversion_error)
			}
			return {}, parse_limit_error(state, .Size_Overflow, start, end, path)
		}
		if status == .Overflow {
			return {}, parse_value_error(state, .Float_Out_Of_Range, start, end, path)
		}
		if status != .Success {
			return {}, parse_value_error(state, .Invalid_Float, start, end, path)
		}
		return Value(Float(float)), nil
	}

	if numeric_candidate {
		integer, error_kind, error_start, error_end, ok := parse_integer_candidate(text)
		if ok {
			return Value(integer), nil
		}
		return {}, parse_value_error(
			state,
			error_kind,
			start+error_start,
			start+error_end,
			path,
		)
	}
	return {}, parse_value_error(state, .Invalid_Value, start, end, path)
}

@(private)
found_syntax_at :: proc(input: string, index: int) -> Parse_Syntax {
	if index >= len(input) {
		return .End_Of_Input
	}
	switch input[index] {
	case '\n', '\r':
		return .End_Of_Line
	case '=':
		return .Equals
	case '.':
		return .Dot
	case ',':
		return .Comma
	case '[':
		return .Left_Bracket
	case ']':
		return .Right_Bracket
	case '{':
		return .Left_Brace
	case '}':
		return .Right_Brace
	}
	return .Other
}

@(private)
skip_horizontal_whitespace :: proc(input: string, start: int) -> int {
	index := start
	for index < len(input) && (input[index] == ' ' || input[index] == '\t') {
		index += 1
	}
	return index
}

@(private)
validate_comment :: proc(
	state: ^Parser_State,
	start: int,
	path: Parser_Diagnostic_Path = .Root,
) -> (int, Parse_Error) {
	index := start+1
	for index < len(state.input) && state.input[index] != '\n' && state.input[index] != '\r' {
		character := state.input[index]
		if character != '\t' && (character < 0x20 || character == 0x7f) {
			return 0, parse_lexical_error(
				state,
				.Invalid_Comment_Character,
				index,
				index+1,
				path,
			)
		}
		index += utf8_scalar_size_at(state.input, index)
	}
	return index, nil
}

@(private)
parser_cleanup :: proc(state: ^Parser_State) {
	parser_release_nodes(state)
	parser_release_binding_ranges(state)
	destroy_table_with_gate(&state.root, &state.gate, state.loc)
}

@(private)
parse_document_internal :: proc(
	input: string,
	options: Parse_Options,
	allocator: runtime.Allocator,
	loc: runtime.Source_Code_Location,
	retained_nodes: ^Parser_Node_Array = nil,
	retained_ranges: ^Binding_Range_Node_Array = nil,
) -> (Document, Parse_Error) {
	if allocator.procedure == nil {
		return {}, Parse_Configuration_Error.Invalid_Allocator
	}
	max_depth := options.max_depth
	if max_depth == 0 {
		max_depth = 128
	} else if max_depth < 1 || max_depth > 256 {
		return {}, Parse_Configuration_Error.Invalid_Max_Depth
	}
	if invalid, found := first_invalid_utf8_byte(input); found {
		return {}, utf8_encoding_diagnostic(input, invalid)
	}

	gate, gate_error := allocator_release_gate_init(allocator, loc)
	if gate_error != nil {
		return {}, gate_error
	}
	state := Parser_State{
		input = input,
		allocator = allocator,
		gate = gate,
		max_depth = max_depth,
		loc = loc,
		capture_binding_ranges = retained_ranges != nil,
	}
	root_error: Parse_Error
	state.root, root_error = parser_make_table(&state, 0, 0, 0, .Root)
	if root_error != nil {
		return {}, root_error
	}
	succeeded := false
	defer if !succeeded {
		parser_cleanup(&state)
	}

	index := 0
	for index < len(input) {
		index = skip_horizontal_whitespace(input, index)
		if index >= len(input) {
			break
		}
		if input[index] == '\n' {
			index += 1
			continue
		}
		if input[index] == '\r' {
			if index+1 >= len(input) || input[index+1] != '\n' {
				return {}, parse_lexical_error(&state, .Invalid_Newline, index, index+1)
			}
			index += 2
			continue
		}
		if input[index] == '#' {
			comment_error: Parse_Error
			index, comment_error = validate_comment(&state, index)
			if comment_error != nil {
				return {}, comment_error
			}
			continue
		}
		if index+3 <= len(input) && input[index:index+3] == "\xef\xbb\xbf" {
			return {}, parse_lexical_error(&state, .Illegal_Character, index, index+3)
		}
		if input[index] < 0x20 || input[index] == 0x7f || input[index] >= 0x80 {
			return {}, parse_lexical_error(
				&state,
				.Illegal_Character,
				index,
				index+utf8_scalar_size_at(input, index),
			)
		}
		expression_error: Parse_Error
		if input[index] == '[' {
			index, expression_error = parse_header_expression(&state, index)
		} else {
			index, expression_error = parse_key_value_expression(&state, index)
		}
		if expression_error != nil {
			return {}, expression_error
		}
	}

	if retained_nodes == nil {
		parser_release_nodes(&state)
	} else {
		retained_nodes^ = state.nodes
		state.nodes = {}
	}
	if retained_ranges == nil {
		parser_release_binding_ranges(&state)
	} else {
		retained_ranges^ = state.binding_ranges
		state.binding_ranges = {}
	}
	document := Document{root = state.root, allocator = allocator}
	state.root = {}
	succeeded = true
	return document, nil
}

@(private)
parse_document :: proc(
	input: string,
	options: Parse_Options,
	allocator: runtime.Allocator,
	loc: runtime.Source_Code_Location,
) -> (Document, Parse_Error) {
	return parse_document_internal(input, options, allocator, loc)
}

@(private)
parse_ranged_document :: proc(
	input: string,
	options: Parse_Options,
	allocator: runtime.Allocator,
	loc: runtime.Source_Code_Location,
) -> (
	document: Document,
	nodes: Parser_Node_Array,
	ranges: Binding_Range_Node_Array,
	err: Parse_Error,
) {
	document, err = parse_document_internal(
		input, options, allocator, loc, &nodes, &ranges,
	)
	return
}

@(private)
destroy_ranged_parse_state :: proc(
	nodes: ^Parser_Node_Array,
	ranges: ^Binding_Range_Node_Array,
	allocator: runtime.Allocator,
	loc: runtime.Source_Code_Location,
) {
	gate, gate_error := allocator_release_gate_init(allocator, loc)
	assert(gate_error == nil)
	if nodes != nil {
		release_owned_memory(
			&gate,
			raw_data(nodes^),
			cap(nodes^)*size_of(Parser_Node),
			loc,
		)
		nodes^ = {}
	}
	if ranges != nil {
		release_owned_memory(
			&gate,
			raw_data(ranges^),
			cap(ranges^)*size_of(Binding_Range_Node),
			loc,
		)
		ranges^ = {}
	}
}

@(require_results)
parse_bytes :: proc(
	input: []byte,
	options: Parse_Options = {},
	allocator := context.allocator,
	loc := #caller_location,
) -> (Document, Parse_Error) {
	return parse_document(string(input), options, allocator, loc)
}

@(require_results)
parse_string :: proc(
	input: string,
	options: Parse_Options = {},
	allocator := context.allocator,
	loc := #caller_location,
) -> (Document, Parse_Error) {
	return parse_document(input, options, allocator, loc)
}

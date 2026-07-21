package toml

import "base:runtime"
import "core:unicode/utf8"

parse :: proc {
	parse_bytes,
	parse_string,
}

@(private)
input_is_document_trivia :: proc(input: string) -> bool {
	for index := 0; index < len(input); {
		switch input[index] {
		case ' ', '\t', '\n':
			index += 1
		case '\r':
			if index+1 >= len(input) || input[index+1] != '\n' {
				return false
			}
			index += 2
		case '#':
			index += 1
			for index < len(input) && input[index] != '\n' && input[index] != '\r' {
				byte := input[index]
				if byte != '\t' && (byte < 0x20 || byte == 0x7f) {
					return false
				}
				index += 1
			}
		case:
			return false
		}
	}
	return true
}

@(private)
parse_empty_document :: proc(
	input: string,
	options: Parse_Options,
	allocator: runtime.Allocator,
	loc: runtime.Source_Code_Location,
) -> (Document, Parse_Error) {
	if allocator.procedure == nil {
		return {}, Parse_Configuration_Error.Invalid_Allocator
	}
	if options.max_depth < 0 || options.max_depth > 256 {
		return {}, Parse_Configuration_Error.Invalid_Max_Depth
	}
	if !utf8.valid_string(input) || !input_is_document_trivia(input) {
		unimplemented("non-empty TOML parsing is scheduled for implementation tickets 11-13")
	}

	root, allocation_error := make(Table, allocator, loc)
	if allocation_error != nil {
		return {}, allocation_error
	}
	return Document{root = root, allocator = allocator}, nil
}

@(require_results)
parse_bytes :: proc(
	input: []byte,
	options: Parse_Options = {},
	allocator := context.allocator,
	loc := #caller_location,
) -> (Document, Parse_Error) {
	return parse_empty_document(string(input), options, allocator, loc)
}

@(require_results)
parse_string :: proc(
	input: string,
	options: Parse_Options = {},
	allocator := context.allocator,
	loc := #caller_location,
) -> (Document, Parse_Error) {
	return parse_empty_document(input, options, allocator, loc)
}

package toml

parse :: proc {
	parse_bytes,
	parse_string,
}

@(require_results)
parse_bytes :: proc(
	input: []byte,
	options: Parse_Options = {},
	allocator := context.allocator,
	loc := #caller_location,
) -> (Document, Parse_Error) {
	_, _, _, _ = input, options, allocator, loc
	unimplemented("TOML parsing is scheduled for implementation tickets 11-13")
}

@(require_results)
parse_string :: proc(
	input: string,
	options: Parse_Options = {},
	allocator := context.allocator,
	loc := #caller_location,
) -> (Document, Parse_Error) {
	_, _, _, _ = input, options, allocator, loc
	unimplemented("TOML parsing is scheduled for implementation tickets 11-13")
}

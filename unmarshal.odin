package toml

@(require_results)
unmarshal :: proc(
	input: []byte,
	destination: ^$T,
	options: Unmarshal_Options = {},
	allocator := context.allocator,
	loc := #caller_location,
) -> Unmarshal_Error {
	_, _, _, _, _ = input, destination, options, allocator, loc
	unimplemented("typed unmarshaling is scheduled for implementation tickets 22-24")
}

@(require_results)
unmarshal_string :: proc(
	input: string,
	destination: ^$T,
	options: Unmarshal_Options = {},
	allocator := context.allocator,
	loc := #caller_location,
) -> Unmarshal_Error {
	_, _, _, _, _ = input, destination, options, allocator, loc
	unimplemented("typed unmarshaling is scheduled for implementation tickets 22-24")
}

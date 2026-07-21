package toml

import "core:io"

@(require_results)
marshal :: proc(
	value: any,
	options: Marshal_Options = {},
	allocator := context.allocator,
	loc := #caller_location,
) -> ([]byte, Marshal_Error) {
	_, _, _, _ = value, options, allocator, loc
	unimplemented("typed marshaling is scheduled for implementation tickets 19-21")
}

@(require_results)
marshal_to_writer :: proc(
	writer: io.Writer,
	value: any,
	options: ^Marshal_Options,
	allocator := context.allocator,
	loc := #caller_location,
) -> Marshal_Error {
	_, _, _, _, _ = writer, value, options, allocator, loc
	unimplemented("typed marshaling is scheduled for implementation tickets 19-21")
}

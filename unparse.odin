package toml

import "core:io"

@(require_results)
unparse :: proc(
	doc: ^Document,
	options: Marshal_Options = {},
	allocator := context.allocator,
	loc := #caller_location,
) -> (string, Unparse_Error) {
	_, _, _, _ = doc, options, allocator, loc
	unimplemented("semantic encoding is scheduled for implementation ticket 15")
}

@(require_results)
unparse_to_writer :: proc(
	writer: io.Writer,
	doc: ^Document,
	options: ^Marshal_Options,
	allocator := context.allocator,
	loc := #caller_location,
) -> Unparse_Error {
	_, _, _, _, _ = writer, doc, options, allocator, loc
	unimplemented("semantic writer encoding is scheduled for implementation ticket 16")
}

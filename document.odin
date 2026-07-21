package toml

import "core:mem"

@(require_results)
clone_document :: proc(
	doc: ^Document,
	allocator := context.allocator,
	loc := #caller_location,
) -> (Document, Clone_Error) {
	_, _, _ = doc, allocator, loc
	unimplemented("semantic ownership is scheduled for implementation ticket 8")
}

destroy_document :: proc(doc: ^Document, loc := #caller_location) {
	_, _ = doc, loc
	unimplemented("semantic ownership is scheduled for implementation ticket 8")
}

@(require_results)
clone_value :: proc(
	value: ^Value,
	allocator := context.allocator,
	loc := #caller_location,
) -> (Value, Clone_Error) {
	_, _, _ = value, allocator, loc
	unimplemented("semantic ownership is scheduled for implementation ticket 8")
}

destroy_value :: proc(
	value: ^Value,
	allocator: mem.Allocator,
	loc := #caller_location,
) {
	_, _, _ = value, allocator, loc
	unimplemented("semantic ownership is scheduled for implementation ticket 8")
}

@(require_results)
get :: proc(table: ^Table, key: string) -> (^Value, bool) {
	_, _ = table, key
	unimplemented("semantic mutation is scheduled for implementation ticket 9")
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

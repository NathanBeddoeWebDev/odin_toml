package main

import "base:runtime"
import "core:mem"
import toml "../.."

Child :: struct {
	name: string,
}

Config :: struct {
	title:  string,
	labels: []string,
	child:  ^Child,
}

INPUT :: `title = "example"
labels = ["first", "second"]
child = { name = "installed" }
`

cleanup_individual :: proc(destination: ^Config, allocator: runtime.Allocator) {
	assert(delete(destination.title, allocator) == nil)
	destination.title = ""
	for &label in destination.labels {
		assert(delete(label, allocator) == nil)
		label = ""
	}
	if raw_data(destination.labels) != nil {
		assert(delete(destination.labels, allocator) == nil)
	}
	destination.labels = nil
	if destination.child != nil {
		assert(delete(destination.child.name, allocator) == nil)
		destination.child.name = ""
		assert(free(destination.child, allocator) == nil)
		destination.child = nil
	}
}

cleanup_external_lifetime :: proc(destination: ^Config) {
	// End access to all package-installed owners. The arena is reclaimed later.
	destination^ = {}
}

has_installed_owner :: proc(destination: ^Config) -> bool {
	return len(destination.title) > 0 || raw_data(destination.labels) != nil ||
	       destination.child != nil
}

Failing_Allocator :: struct {
	backing:          runtime.Allocator,
	fail_at:          int,
	allocation_count: int,
}

failing_allocator :: proc(state: ^Failing_Allocator) -> runtime.Allocator {
	return {procedure = failing_allocator_proc, data = state}
}

failing_allocator_proc :: proc(
	allocator_data: rawptr,
	mode: runtime.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	loc := #caller_location,
) -> ([]byte, runtime.Allocator_Error) {
	state := (^Failing_Allocator)(allocator_data)
	if mode == .Alloc || mode == .Alloc_Non_Zeroed ||
	   mode == .Resize || mode == .Resize_Non_Zeroed {
		state.allocation_count += 1
		if state.allocation_count == state.fail_at {
			return nil, .Out_Of_Memory
		}
	}
	return state.backing.procedure(
		state.backing.data, mode, size, alignment, old_memory, old_size, loc,
	)
}

individually_freeing_examples :: proc() {
	complete: Config
	assert(toml.unmarshal_string(INPUT, &complete) == nil)
	cleanup_individual(&complete, context.allocator)
	assert(!has_installed_owner(&complete))

	saw_partial := false
	for ordinal in 1..=128 {
		state := Failing_Allocator{backing = context.allocator, fail_at = ordinal}
		allocator := failing_allocator(&state)
		partial: Config
		err := toml.unmarshal_string(INPUT, &partial, allocator = allocator)
		if err != nil && has_installed_owner(&partial) {
			saw_partial = true
		}
		cleanup_individual(&partial, allocator)
		assert(!has_installed_owner(&partial))
		if saw_partial {
			break
		}
	}
	assert(saw_partial)
}

external_lifetime_examples :: proc() {
	complete_arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&complete_arena)
	complete_allocator := mem.dynamic_arena_allocator(&complete_arena)
	complete: Config
	assert(toml.unmarshal_string(INPUT, &complete, allocator = complete_allocator) == nil)
	cleanup_external_lifetime(&complete)
	mem.dynamic_arena_destroy(&complete_arena)
	assert(!has_installed_owner(&complete))

	saw_partial := false
	for ordinal in 1..=128 {
		arena: mem.Dynamic_Arena
		mem.dynamic_arena_init(&arena)
		state := Failing_Allocator{
			backing = mem.dynamic_arena_allocator(&arena),
			fail_at = ordinal,
		}
		allocator := failing_allocator(&state)
		partial: Config
		err := toml.unmarshal_string(INPUT, &partial, allocator = allocator)
		if err != nil && has_installed_owner(&partial) {
			saw_partial = true
		}
		cleanup_external_lifetime(&partial)
		mem.dynamic_arena_destroy(&arena)
		assert(!has_installed_owner(&partial))
		if saw_partial {
			break
		}
	}
	assert(saw_partial)
}

main :: proc() {
	individually_freeing_examples()
	external_lifetime_examples()
}

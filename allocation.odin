package toml

import "base:runtime"
import "core:mem"

@(private)
TOML_ALLOCATOR_GATE_TESTING :: #config(TOML_ALLOCATOR_GATE_TESTING, false)

// These requests deliberately call the selected allocator directly. Reference
// Odin's generic resize helper retries .Mode_Not_Implemented as alloc-copy-free,
// which would erase the exact unsupported-mode error required by this package.
@(private)
allocator_allocate :: proc(
	size: int,
	allocator: mem.Allocator,
	zero_memory := true,
	loc := #caller_location,
) -> (memory: rawptr, err: runtime.Allocator_Error) {
	if allocator.procedure == nil {
		return nil, .Invalid_Argument
	}
	mode := runtime.Allocator_Mode.Alloc
	if !zero_memory {
		mode = .Alloc_Non_Zeroed
	}
	result: []byte
	result, err = allocator.procedure(
		allocator.data,
		mode,
		size,
		mem.DEFAULT_ALIGNMENT,
		nil,
		0,
		loc,
	)
	return raw_data(result), err
}

@(private)
allocator_resize :: proc(
	memory: rawptr,
	old_size, new_size: int,
	allocator: mem.Allocator,
	zero_memory := true,
	loc := #caller_location,
) -> (resized: rawptr, err: runtime.Allocator_Error) {
	if allocator.procedure == nil {
		return nil, .Invalid_Argument
	}
	mode := runtime.Allocator_Mode.Resize
	if !zero_memory {
		mode = .Resize_Non_Zeroed
	}
	result: []byte
	result, err = allocator.procedure(
		allocator.data,
		mode,
		new_size,
		mem.DEFAULT_ALIGNMENT,
		memory,
		old_size,
		loc,
	)
	return raw_data(result), err
}

// The gate governs physical release only. Lifecycle walkers remain responsible
// for recursively zeroing every logical owner on both release strategies.
@(private)
Allocator_Release_Mode :: enum u8 {
	Unknown,
	Individual,
	Logical,
}

@(private)
Allocator_Release_Gate :: struct {
	allocator: mem.Allocator,
	mode:      Allocator_Release_Mode,
}

@(private)
allocator_release_gate_init :: proc(
	allocator: mem.Allocator,
	loc := #caller_location,
) -> (gate: Allocator_Release_Gate, err: runtime.Allocator_Error) {
	if allocator.procedure == nil {
		return {}, .Invalid_Argument
	}

	features: runtime.Allocator_Mode_Set
	_, err = allocator.procedure(
		allocator.data,
		.Query_Features,
		0,
		0,
		&features,
		0,
		loc,
	)
	if err == .Mode_Not_Implemented {
		return {allocator = allocator, mode = .Unknown}, nil
	}
	if err != nil {
		return {}, err
	}
	mode := Allocator_Release_Mode.Logical
	if .Free in features {
		mode = .Individual
	}
	return {allocator = allocator, mode = mode}, nil
}

@(private)
allocator_release_gate_release :: proc(
	gate: ^Allocator_Release_Gate,
	memory: rawptr,
	memory_size: int,
	loc := #caller_location,
) -> runtime.Allocator_Error {
	if gate == nil || gate.allocator.procedure == nil {
		return .Invalid_Argument
	}
	if memory == nil || gate.mode == .Logical {
		return nil
	}

	_, err := gate.allocator.procedure(
		gate.allocator.data,
		.Free,
		0,
		0,
		memory,
		memory_size,
		loc,
	)
	if gate.mode == .Unknown {
		if err == .Mode_Not_Implemented {
			gate.mode = .Logical
			return nil
		}
		if err == nil {
			gate.mode = .Individual
		}
	}
	return err
}

when TOML_ALLOCATOR_GATE_TESTING {
	allocator_allocate_gate_test :: proc(
		size: int,
		allocator: mem.Allocator,
		zero_memory := true,
		loc := #caller_location,
	) -> (rawptr, runtime.Allocator_Error) {
		return allocator_allocate(size, allocator, zero_memory, loc)
	}

	allocator_resize_gate_test :: proc(
		memory: rawptr,
		old_size, new_size: int,
		allocator: mem.Allocator,
		zero_memory := true,
		loc := #caller_location,
	) -> (rawptr, runtime.Allocator_Error) {
		return allocator_resize(memory, old_size, new_size, allocator, zero_memory, loc)
	}

	Allocator_Release_Gate_Test_State :: struct {
		gate: Allocator_Release_Gate,
	}

	allocator_release_gate_test_init :: proc(
		allocator: mem.Allocator,
		loc := #caller_location,
	) -> (state: Allocator_Release_Gate_Test_State, err: runtime.Allocator_Error) {
		state.gate, err = allocator_release_gate_init(allocator, loc)
		return
	}

	allocator_release_gate_test_release :: proc(
		state: ^Allocator_Release_Gate_Test_State,
		memory: rawptr,
		memory_size: int,
		loc := #caller_location,
	) -> runtime.Allocator_Error {
		return allocator_release_gate_release(&state.gate, memory, memory_size, loc)
	}

	allocator_release_gate_test_is_logical :: proc(
		state: ^Allocator_Release_Gate_Test_State,
	) -> bool {
		return state.gate.mode == .Logical
	}
}

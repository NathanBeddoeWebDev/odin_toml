package test_support

import "base:runtime"
import "core:mem"

// Observed_Allocator borrows its event and live-allocation storage. This keeps
// allocator instrumentation from allocating recursively or touching the ambient
// allocator. Allocation failure ordinals are one-based; zero disables failure.
Allocator_Event_Kind :: enum u8 {
	Alloc,
	Alloc_Non_Zeroed,
	Resize,
	Resize_Non_Zeroed,
	Release,
	Foreign_Release,
	Free_All,
	Query_Features,
	Query_Info,
}

Allocator_Event :: struct {
	ordinal:            int,
	kind:               Allocator_Event_Kind,
	kind_ordinal:       int,
	allocating_ordinal: int,
	size:               int,
	alignment:          int,
	old_memory:         rawptr,
	old_size:           int,
	result_memory:      rawptr,
	foreign_memory:     bool,
	error:              runtime.Allocator_Error,
}

Live_Allocation :: struct {
	memory:    rawptr,
	size:      int,
	alignment: int,
	mode:      runtime.Allocator_Mode,
}

Observed_Allocator :: struct {
	backing: runtime.Allocator,

	events:              []Allocator_Event,
	event_count:         int,
	dropped_event_count: int,
	kind_counts:         [Allocator_Event_Kind]int,

	live:                []Live_Allocation,
	live_count:          int,
	live_overflow_count: int,

	allocation_request_count: int,
	release_count:            int,
	foreign_release_count:    int,
	foreign_resize_count:     int,
	fail_at_allocation:       int,
	failure_error:            runtime.Allocator_Error,
}

observed_allocator_init :: proc(
	state: ^Observed_Allocator,
	backing: runtime.Allocator,
	event_storage: []Allocator_Event,
	live_storage: []Live_Allocation,
) {
	state^ = {}
	state.backing = backing
	state.events = event_storage
	state.live = live_storage
	state.failure_error = .Out_Of_Memory
}

@(require_results)
observed_allocator :: proc(state: ^Observed_Allocator) -> mem.Allocator {
	return {procedure = observed_allocator_proc, data = state}
}

observed_allocator_proc :: proc(
	allocator_data: rawptr,
	mode: runtime.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	loc := #caller_location,
) -> (result: []byte, err: runtime.Allocator_Error) {
	state := (^Observed_Allocator)(allocator_data)
	kind := allocator_event_kind(state, mode, old_memory)
	state.kind_counts[kind] += 1
	kind_ordinal := state.kind_counts[kind]

	allocating_ordinal := 0
	if mode == .Alloc || mode == .Alloc_Non_Zeroed ||
	   mode == .Resize || mode == .Resize_Non_Zeroed {
		state.allocation_request_count += 1
		allocating_ordinal = state.allocation_request_count
	}

	foreign_memory := (mode == .Resize || mode == .Resize_Non_Zeroed) &&
	                  old_memory != nil && observed_find_live(state, old_memory) < 0
	event_index := observed_record_event(state, Allocator_Event{
		ordinal = state.event_count + 1,
		kind = kind,
		kind_ordinal = kind_ordinal,
		allocating_ordinal = allocating_ordinal,
		size = size,
		alignment = alignment,
		old_memory = old_memory,
		old_size = old_size,
		foreign_memory = foreign_memory,
	})

	if kind == .Foreign_Release {
		state.foreign_release_count += 1
		err = .Invalid_Pointer
		observed_finish_event(state, event_index, result, err)
		return
	}

	if foreign_memory {
		state.foreign_resize_count += 1
		err = .Invalid_Pointer
		observed_finish_event(state, event_index, result, err)
		return
	}

	if allocating_ordinal > 0 &&
	   state.fail_at_allocation == allocating_ordinal {
		err = state.failure_error
		observed_finish_event(state, event_index, result, err)
		return
	}

	needs_new_live_slot := (mode == .Alloc || mode == .Alloc_Non_Zeroed ||
	                       ((mode == .Resize || mode == .Resize_Non_Zeroed) && old_memory == nil)) &&
	                      size > 0
	if needs_new_live_slot && state.live_count >= len(state.live) {
		state.live_overflow_count += 1
		err = .Out_Of_Memory
		observed_finish_event(state, event_index, result, err)
		return
	}

	if state.backing.procedure == nil {
		err = .Out_Of_Memory
		observed_finish_event(state, event_index, result, err)
		return
	}

	result, err = state.backing.procedure(
		state.backing.data,
		mode,
		size,
		alignment,
		old_memory,
		old_size,
		loc,
	)

	if err == nil {
		#partial switch mode {
		case .Alloc, .Alloc_Non_Zeroed:
			if raw_data(result) != nil {
				observed_add_live(state, raw_data(result), size, alignment, mode)
			}
		case .Resize, .Resize_Non_Zeroed:
			old_index := observed_find_live(state, old_memory)
			if old_index >= 0 {
				observed_remove_live(state, old_index)
			}
			if raw_data(result) != nil {
				observed_add_live(state, raw_data(result), size, alignment, mode)
			}
		case .Free:
			old_index := observed_find_live(state, old_memory)
			if old_index >= 0 {
				observed_remove_live(state, old_index)
			}
			state.release_count += 1
		case .Free_All:
			for index in 0 ..< state.live_count {
				state.live[index] = {}
			}
			state.live_count = 0
		}
	}

	observed_finish_event(state, event_index, result, err)
	return
}

allocator_event_kind :: proc(
	state: ^Observed_Allocator,
	mode: runtime.Allocator_Mode,
	old_memory: rawptr,
) -> Allocator_Event_Kind {
	switch mode {
	case .Alloc:
		return .Alloc
	case .Alloc_Non_Zeroed:
		return .Alloc_Non_Zeroed
	case .Resize:
		return .Resize
	case .Resize_Non_Zeroed:
		return .Resize_Non_Zeroed
	case .Free:
		if old_memory != nil && observed_find_live(state, old_memory) < 0 {
			return .Foreign_Release
		}
		return .Release
	case .Free_All:
		return .Free_All
	case .Query_Features:
		return .Query_Features
	case .Query_Info:
		return .Query_Info
	}
	unreachable()
}

observed_record_event :: proc(state: ^Observed_Allocator, event: Allocator_Event) -> int {
	state.event_count += 1
	index := state.event_count - 1
	if index >= len(state.events) {
		state.dropped_event_count += 1
		return -1
	}
	state.events[index] = event
	return index
}

observed_finish_event :: proc(
	state: ^Observed_Allocator,
	index: int,
	result: []byte,
	err: runtime.Allocator_Error,
) {
	if index < 0 {
		return
	}
	state.events[index].result_memory = raw_data(result)
	state.events[index].error = err
}

observed_find_live :: proc(state: ^Observed_Allocator, memory: rawptr) -> int {
	for allocation, index in state.live[:state.live_count] {
		if allocation.memory == memory {
			return index
		}
	}
	return -1
}

observed_add_live :: proc(
	state: ^Observed_Allocator,
	memory: rawptr,
	size, alignment: int,
	mode: runtime.Allocator_Mode,
) {
	assert(state.live_count < len(state.live))
	state.live[state.live_count] = {memory, size, alignment, mode}
	state.live_count += 1
}

observed_remove_live :: proc(state: ^Observed_Allocator, index: int) {
	assert(0 <= index && index < state.live_count)
	last := state.live_count - 1
	state.live[index] = state.live[last]
	state.live[last] = {}
	state.live_count = last
}

// Rejecting_Allocator is intended for context.allocator while a package call
// receives another allocator explicitly. Any non-query call is observable and
// rejected, turning an accidental ambient fallback into a deterministic test
// failure rather than an unnoticed allocation.
Rejecting_Allocator :: struct {
	call_count:               int,
	allocation_attempt_count: int,
	mode_counts:              [runtime.Allocator_Mode]int,
}

@(require_results)
rejecting_allocator :: proc(state: ^Rejecting_Allocator) -> mem.Allocator {
	return {procedure = rejecting_allocator_proc, data = state}
}

rejecting_allocator_proc :: proc(
	allocator_data: rawptr,
	mode: runtime.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	loc := #caller_location,
) -> ([]byte, runtime.Allocator_Error) {
	_, _, _, _, _ = size, alignment, old_memory, old_size, loc
	state := (^Rejecting_Allocator)(allocator_data)
	state.call_count += 1
	state.mode_counts[mode] += 1

	switch mode {
	case .Alloc, .Alloc_Non_Zeroed, .Resize, .Resize_Non_Zeroed:
		state.allocation_attempt_count += 1
		return nil, .Out_Of_Memory
	case .Free:
		return nil, .Invalid_Pointer
	case .Free_All:
		return nil, .Mode_Not_Implemented
	case .Query_Features:
		features := (^runtime.Allocator_Mode_Set)(old_memory)
		if features != nil {
			features^ = {.Query_Features}
		}
		return nil, nil
	case .Query_Info:
		return nil, .Mode_Not_Implemented
	}
	unreachable()
}

// External_Lifetime_Allocator exposes an arena-style lifetime while ensuring
// individual releases are never forwarded to its backing allocator. In the
// reporting mode Query_Features succeeds and omits .Free. In the unsupported
// mode feature discovery itself returns .Mode_Not_Implemented, exercising the
// package's fallback-to-logical-destruction branch.
External_Lifetime_Allocator :: struct {
	backing: runtime.Allocator,
	report_features: bool,
	call_count: int,
	allocation_request_count: int,
	release_attempt_count: int,
	free_all_count: int,
	query_features_count: int,
}

external_lifetime_allocator_init :: proc(
	state: ^External_Lifetime_Allocator,
	backing: runtime.Allocator,
	report_features: bool,
) {
	state^ = {}
	state.backing = backing
	state.report_features = report_features
}

@(require_results)
external_lifetime_allocator :: proc(state: ^External_Lifetime_Allocator) -> mem.Allocator {
	return {procedure = external_lifetime_allocator_proc, data = state}
}

external_lifetime_allocator_proc :: proc(
	allocator_data: rawptr,
	mode: runtime.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	loc := #caller_location,
) -> ([]byte, runtime.Allocator_Error) {
	state := (^External_Lifetime_Allocator)(allocator_data)
	state.call_count += 1

	switch mode {
	case .Free:
		state.release_attempt_count += 1
		return nil, .Mode_Not_Implemented
	case .Query_Features:
		state.query_features_count += 1
		if !state.report_features || state.backing.procedure == nil {
			return nil, .Mode_Not_Implemented
		}
		backing_features: runtime.Allocator_Mode_Set
		_, backing_err := state.backing.procedure(
			state.backing.data,
			.Query_Features,
			0,
			0,
			&backing_features,
			0,
			loc,
		)
		if backing_err != nil {
			return nil, backing_err
		}
		backing_features -= {.Free}
		backing_features += {.Query_Features}
		features := (^runtime.Allocator_Mode_Set)(old_memory)
		if features != nil {
			features^ = backing_features
		}
		return nil, nil
	case .Alloc, .Alloc_Non_Zeroed, .Resize, .Resize_Non_Zeroed:
		state.allocation_request_count += 1
	case .Free_All:
		state.free_all_count += 1
	case .Query_Info:
	}

	if state.backing.procedure == nil {
		return nil, .Mode_Not_Implemented
	}
	return state.backing.procedure(
		state.backing.data,
		mode,
		size,
		alignment,
		old_memory,
		old_size,
		loc,
	)
}

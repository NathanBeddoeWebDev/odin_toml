package allocator_gate_test

import "base:runtime"
import "core:mem"
import "core:testing"
import toml "../.."
import test_support "../support"

Release_Behavior_Allocator :: struct {
	report_features:     bool,
	first_free_succeeds: bool,
	query_error:         runtime.Allocator_Error,
	free_count:          int,
}

release_behavior_allocator :: proc(state: ^Release_Behavior_Allocator) -> mem.Allocator {
	return {procedure = release_behavior_allocator_proc, data = state}
}

release_behavior_allocator_proc :: proc(
	allocator_data: rawptr,
	mode: runtime.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	loc := #caller_location,
) -> ([]byte, runtime.Allocator_Error) {
	_, _, _, _, _ = size, alignment, old_memory, old_size, loc
	state := (^Release_Behavior_Allocator)(allocator_data)
	switch mode {
	case .Query_Features:
		if state.query_error != nil {
			return nil, state.query_error
		}
		if !state.report_features {
			return nil, .Mode_Not_Implemented
		}
		features := (^runtime.Allocator_Mode_Set)(old_memory)
		if features != nil {
			features^ = {.Free, .Query_Features}
		}
		return nil, nil
	case .Free:
		state.free_count += 1
		if state.first_free_succeeds && state.free_count == 1 {
			return nil, nil
		}
		return nil, .Mode_Not_Implemented
	case .Alloc, .Alloc_Non_Zeroed, .Resize, .Resize_Non_Zeroed, .Free_All, .Query_Info:
		return nil, .Mode_Not_Implemented
	}
	unreachable()
}

@(test)
test_individual_release_gate_frees_in_arbitrary_order_and_preserves_errors :: proc(t: ^testing.T) {
	backing := context.allocator
	events: [32]test_support.Allocator_Event
	live: [8]test_support.Live_Allocation
	observed: test_support.Observed_Allocator
	test_support.observed_allocator_init(&observed, backing, events[:], live[:])
	selected := test_support.observed_allocator(&observed)

	rejecting: test_support.Rejecting_Allocator
	context.allocator = test_support.rejecting_allocator(&rejecting)
	defer context.allocator = backing

	first, first_error := mem.alloc(1, allocator = selected)
	second, second_error := mem.alloc(1, allocator = selected)
	third, third_error := mem.alloc(1, allocator = selected)
	testing.expect_value(t, first_error, runtime.Allocator_Error.None)
	testing.expect_value(t, second_error, runtime.Allocator_Error.None)
	testing.expect_value(t, third_error, runtime.Allocator_Error.None)

	gate, gate_error := toml.allocator_release_gate_test_init(selected)
	testing.expect_value(t, gate_error, runtime.Allocator_Error.None)
	testing.expect_value(
		t,
		toml.allocator_release_gate_test_release(&gate, second, 1),
		runtime.Allocator_Error.None,
	)
	testing.expect_value(
		t,
		toml.allocator_release_gate_test_release(&gate, first, 1),
		runtime.Allocator_Error.None,
	)
	testing.expect_value(
		t,
		toml.allocator_release_gate_test_release(&gate, third, 1),
		runtime.Allocator_Error.None,
	)

	outsider: [1]byte
	testing.expect_value(
		t,
		toml.allocator_release_gate_test_release(&gate, raw_data(outsider[:]), 1),
		runtime.Allocator_Error.Invalid_Pointer,
	)
	testing.expect_value(t, observed.live_count, 0)
	testing.expect_value(t, observed.release_count, 3)
	for event_index in 4 ..= 7 {
		testing.expect_value(t, observed.events[event_index].old_size, 1)
	}
	testing.expect_value(t, observed.foreign_release_count, 1)
	testing.expect_value(t, rejecting.call_count, 0)
}

@(test)
test_lifo_allocator_cannot_satisfy_arbitrary_order_release_contract :: proc(t: ^testing.T) {
	buffer: [256]byte
	stack: mem.Stack
	mem.stack_init(&stack, buffer[:])
	selected := mem.stack_allocator(&stack)
	first, first_error := mem.alloc(8, allocator = selected)
	second, second_error := mem.alloc(8, allocator = selected)
	testing.expect_value(t, first_error, runtime.Allocator_Error.None)
	testing.expect_value(t, second_error, runtime.Allocator_Error.None)

	backing := context.allocator
	rejecting: test_support.Rejecting_Allocator
	context.allocator = test_support.rejecting_allocator(&rejecting)
	defer context.allocator = backing

	gate, gate_error := toml.allocator_release_gate_test_init(selected)
	testing.expect_value(t, gate_error, runtime.Allocator_Error.None)
	testing.expect_value(
		t,
		toml.allocator_release_gate_test_release(&gate, first, 8),
		runtime.Allocator_Error.Invalid_Pointer,
	)

	// This allocator is deliberately outside the ownership contract. Restore
	// its stack in LIFO order after proving arbitrary-order destruction fails.
	testing.expect_value(t, mem.free(second, selected), runtime.Allocator_Error.None)
	testing.expect_value(t, mem.free(first, selected), runtime.Allocator_Error.None)
	testing.expect_value(t, rejecting.call_count, 0)
}

@(test)
test_external_lifetime_release_gate_selects_logical_destruction_only :: proc(t: ^testing.T) {
	buffer: [256]byte
	arena: mem.Arena
	mem.arena_init(&arena, buffer[:])

	reported: test_support.External_Lifetime_Allocator
	test_support.external_lifetime_allocator_init(
		&reported,
		mem.arena_allocator(&arena),
		true,
	)
	reported_allocator := test_support.external_lifetime_allocator(&reported)
	reported_bytes, reported_error := mem.alloc(16, allocator = reported_allocator)
	testing.expect_value(t, reported_error, runtime.Allocator_Error.None)

	reported_gate, gate_error := toml.allocator_release_gate_test_init(reported_allocator)
	testing.expect_value(t, gate_error, runtime.Allocator_Error.None)
	testing.expect(t, toml.allocator_release_gate_test_is_logical(&reported_gate))
	testing.expect_value(
		t,
		toml.allocator_release_gate_test_release(&reported_gate, reported_bytes, 16),
		runtime.Allocator_Error.None,
	)
	testing.expect_value(t, reported.release_attempt_count, 0)
	testing.expect_value(t, reported.free_all_count, 0)
	testing.expect(t, arena.offset > 0)

	unsupported: test_support.External_Lifetime_Allocator
	test_support.external_lifetime_allocator_init(
		&unsupported,
		mem.arena_allocator(&arena),
		false,
	)
	unsupported_allocator := test_support.external_lifetime_allocator(&unsupported)
	first, first_error := mem.alloc(8, allocator = unsupported_allocator)
	second, second_error := mem.alloc(8, allocator = unsupported_allocator)
	testing.expect_value(t, first_error, runtime.Allocator_Error.None)
	testing.expect_value(t, second_error, runtime.Allocator_Error.None)

	unsupported_gate, unsupported_gate_error := toml.allocator_release_gate_test_init(
		unsupported_allocator,
	)
	testing.expect_value(t, unsupported_gate_error, runtime.Allocator_Error.None)
	testing.expect(
		t,
		!toml.allocator_release_gate_test_is_logical(&unsupported_gate),
	)
	testing.expect_value(
		t,
		toml.allocator_release_gate_test_release(&unsupported_gate, first, 8),
		runtime.Allocator_Error.None,
	)
	testing.expect(t, toml.allocator_release_gate_test_is_logical(&unsupported_gate))
	testing.expect_value(
		t,
		toml.allocator_release_gate_test_release(&unsupported_gate, second, 8),
		runtime.Allocator_Error.None,
	)
	testing.expect_value(t, unsupported.release_attempt_count, 1)
	testing.expect_value(t, unsupported.free_all_count, 0)
	testing.expect(t, arena.offset > 0)

	mem.arena_free_all(&arena)
}

@(test)
test_mode_not_implemented_only_transitions_before_an_individual_release_succeeds :: proc(t: ^testing.T) {
	reported: Release_Behavior_Allocator
	reported.report_features = true
	reported_gate, reported_gate_error := toml.allocator_release_gate_test_init(
		release_behavior_allocator(&reported),
	)
	testing.expect_value(t, reported_gate_error, runtime.Allocator_Error.None)
	testing.expect_value(
		t,
		toml.allocator_release_gate_test_release(&reported_gate, rawptr(uintptr(1)), 1),
		runtime.Allocator_Error.Mode_Not_Implemented,
	)
	testing.expect(t, !toml.allocator_release_gate_test_is_logical(&reported_gate))

	unreported: Release_Behavior_Allocator
	unreported.first_free_succeeds = true
	unreported_gate, unreported_gate_error := toml.allocator_release_gate_test_init(
		release_behavior_allocator(&unreported),
	)
	testing.expect_value(t, unreported_gate_error, runtime.Allocator_Error.None)
	testing.expect_value(
		t,
		toml.allocator_release_gate_test_release(&unreported_gate, rawptr(uintptr(1)), 1),
		runtime.Allocator_Error.None,
	)
	testing.expect_value(
		t,
		toml.allocator_release_gate_test_release(&unreported_gate, rawptr(uintptr(2)), 1),
		runtime.Allocator_Error.Mode_Not_Implemented,
	)
	testing.expect(t, !toml.allocator_release_gate_test_is_logical(&unreported_gate))
	testing.expect_value(t, unreported.free_count, 2)

	query_failure: Release_Behavior_Allocator
	query_failure.query_error = .Invalid_Pointer
	_, query_error := toml.allocator_release_gate_test_init(
		release_behavior_allocator(&query_failure),
	)
	testing.expect_value(
		t,
		query_error,
		runtime.Allocator_Error.Invalid_Pointer,
	)
}

@(test)
test_unsupported_allocation_and_resize_errors_remain_exact :: proc(t: ^testing.T) {
	backing := context.allocator
	events: [16]test_support.Allocator_Event
	live: [4]test_support.Live_Allocation
	observed: test_support.Observed_Allocator
	test_support.observed_allocator_init(&observed, backing, events[:], live[:])
	observed.failure_error = .Mode_Not_Implemented
	observed.fail_at_allocation = 1
	selected := test_support.observed_allocator(&observed)

	rejecting: test_support.Rejecting_Allocator
	context.allocator = test_support.rejecting_allocator(&rejecting)
	defer context.allocator = backing

	allocation, allocation_error := toml.allocator_allocate_gate_test(8, selected)
	testing.expect_value(t, allocation, rawptr(nil))
	testing.expect_value(
		t,
		allocation_error,
		runtime.Allocator_Error.Mode_Not_Implemented,
	)

	observed.fail_at_allocation = observed.allocation_request_count + 1
	nonzero_allocation, nonzero_allocation_error := toml.allocator_allocate_gate_test(
		8,
		selected,
		false,
	)
	testing.expect_value(t, nonzero_allocation, rawptr(nil))
	testing.expect_value(
		t,
		nonzero_allocation_error,
		runtime.Allocator_Error.Mode_Not_Implemented,
	)

	observed.fail_at_allocation = 0
	resize_source, source_error := mem.alloc(8, allocator = selected)
	testing.expect_value(t, source_error, runtime.Allocator_Error.None)
	observed.fail_at_allocation = observed.allocation_request_count + 1
	resized, resize_error := toml.allocator_resize_gate_test(
		resize_source,
		8,
		16,
		selected,
	)
	testing.expect_value(t, resized, rawptr(nil))
	testing.expect_value(
		t,
		resize_error,
		runtime.Allocator_Error.Mode_Not_Implemented,
	)

	observed.fail_at_allocation = observed.allocation_request_count + 1
	nonzero_resized, nonzero_resize_error := toml.allocator_resize_gate_test(
		resize_source,
		8,
		16,
		selected,
		false,
	)
	testing.expect_value(t, nonzero_resized, rawptr(nil))
	testing.expect_value(
		t,
		nonzero_resize_error,
		runtime.Allocator_Error.Mode_Not_Implemented,
	)

	observed.fail_at_allocation = 0
	testing.expect_value(
		t,
		mem.free(resize_source, selected),
		runtime.Allocator_Error.None,
	)
	testing.expect_value(t, observed.live_count, 0)
	testing.expect_value(t, observed.events[0].kind, test_support.Allocator_Event_Kind.Alloc)
	testing.expect_value(
		t,
		observed.events[1].kind,
		test_support.Allocator_Event_Kind.Alloc_Non_Zeroed,
	)
	testing.expect_value(t, observed.events[3].kind, test_support.Allocator_Event_Kind.Resize)
	testing.expect_value(
		t,
		observed.events[4].kind,
		test_support.Allocator_Event_Kind.Resize_Non_Zeroed,
	)
	testing.expect_value(t, rejecting.call_count, 0)
}

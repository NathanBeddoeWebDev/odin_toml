package test_support

import "base:runtime"
import "core:mem"
import "core:testing"

@(test)
test_observed_allocator_accounts_for_calls_and_failures_by_ordinal :: proc(t: ^testing.T) {
	event_storage: [32]Allocator_Event
	live_storage:  [8]Live_Allocation
	state: Observed_Allocator
	observed_allocator_init(
		&state,
		context.allocator,
		event_storage[:],
		live_storage[:],
	)
	allocator := observed_allocator(&state)

	first, first_err := mem.alloc_bytes(8, allocator = allocator)
	testing.expect_value(t, first_err, runtime.Allocator_Error.None)
	second, second_err := mem.alloc_bytes_non_zeroed(4, allocator = allocator)
	testing.expect_value(t, second_err, runtime.Allocator_Error.None)
	resized_first, resize_err := mem.resize_bytes(first, 12, allocator = allocator)
	testing.expect_value(t, resize_err, runtime.Allocator_Error.None)
	resized_second, resize_nonzero_err := mem.resize_bytes_non_zeroed(second, 9, allocator = allocator)
	testing.expect_value(t, resize_nonzero_err, runtime.Allocator_Error.None)
	testing.expect_value(t, mem.free_bytes(resized_first, allocator), runtime.Allocator_Error.None)
	testing.expect_value(t, mem.free_bytes(resized_second, allocator), runtime.Allocator_Error.None)

	outsider: [1]byte
	foreign_err := mem.free(raw_data(outsider[:]), allocator)
	testing.expect_value(t, foreign_err, runtime.Allocator_Error.Invalid_Pointer)

	expected_kinds := [7]Allocator_Event_Kind{
		.Alloc,
		.Alloc_Non_Zeroed,
		.Resize,
		.Resize_Non_Zeroed,
		.Release,
		.Release,
		.Foreign_Release,
	}
	expected_kind_ordinals := [7]int{1, 1, 1, 1, 1, 2, 1}
	testing.expect_value(t, state.event_count, len(expected_kinds))
	for kind, index in expected_kinds {
		event := state.events[index]
		testing.expect_value(t, event.kind, kind)
		testing.expect_value(t, event.ordinal, index + 1)
		testing.expect_value(t, event.kind_ordinal, expected_kind_ordinals[index])
	}
	testing.expect_value(t, state.allocation_request_count, 4)
	testing.expect_value(t, state.release_count, 2)
	testing.expect_value(t, state.foreign_release_count, 1)
	testing.expect_value(t, state.live_count, 0)
	testing.expect_value(t, state.dropped_event_count, 0)

	fail_events: [8]Allocator_Event
	fail_live:   [4]Live_Allocation
	failing: Observed_Allocator
	observed_allocator_init(&failing, context.allocator, fail_events[:], fail_live[:])
	failing.fail_at_allocation = 2
	fail_allocator := observed_allocator(&failing)

	kept, kept_err := mem.alloc_bytes(1, allocator = fail_allocator)
	testing.expect_value(t, kept_err, runtime.Allocator_Error.None)
	failed, failed_err := mem.alloc_bytes_non_zeroed(1, allocator = fail_allocator)
	testing.expect_value(t, failed_err, runtime.Allocator_Error.Out_Of_Memory)
	testing.expect_value(t, len(failed), 0)
	testing.expect_value(t, failing.events[1].allocating_ordinal, 2)
	testing.expect_value(t, failing.events[1].error, runtime.Allocator_Error.Out_Of_Memory)
	testing.expect_value(t, mem.free_bytes(kept, fail_allocator), runtime.Allocator_Error.None)
	testing.expect_value(t, failing.live_count, 0)
}

@(test)
test_observed_allocator_fails_each_allocating_mode_by_ordinal :: proc(t: ^testing.T) {
	expected_kinds := [4]Allocator_Event_Kind{
		.Alloc,
		.Alloc_Non_Zeroed,
		.Resize,
		.Resize_Non_Zeroed,
	}
	for fail_at in 1 ..= len(expected_kinds) {
		events: [16]Allocator_Event
		live: [8]Live_Allocation
		state: Observed_Allocator
		observed_allocator_init(&state, context.allocator, events[:], live[:])
		allocator := observed_allocator(&state)

		resize_source, resize_source_err := mem.alloc(1, allocator = allocator)
		resize_nonzero_source, resize_nonzero_source_err := mem.alloc(1, allocator = allocator)
		testing.expect_value(t, resize_source_err, runtime.Allocator_Error.None)
		testing.expect_value(t, resize_nonzero_source_err, runtime.Allocator_Error.None)
		state.event_count = 0
		state.dropped_event_count = 0
		state.kind_counts = {}
		state.allocation_request_count = 0
		state.fail_at_allocation = fail_at

		alloc_result, alloc_err := mem.alloc_bytes(1, allocator = allocator)
		nonzero_result, nonzero_err := mem.alloc_bytes_non_zeroed(1, allocator = allocator)
		resized, resize_err := mem.resize(resize_source, 1, 2, allocator = allocator)
		if resize_err == nil {
			resize_source = resized
		}
		resized_nonzero, resize_nonzero_err := mem.resize_non_zeroed(
			resize_nonzero_source,
			1,
			2,
			allocator = allocator,
		)
		if resize_nonzero_err == nil {
			resize_nonzero_source = resized_nonzero
		}
		errors := [4]runtime.Allocator_Error{alloc_err, nonzero_err, resize_err, resize_nonzero_err}
		for err, index in errors {
			expected_error := runtime.Allocator_Error.None
			if index + 1 == fail_at {
				expected_error = .Out_Of_Memory
			}
			testing.expect_value(t, err, expected_error)
			testing.expect_value(t, state.events[index].kind, expected_kinds[index])
			testing.expect_value(t, state.events[index].allocating_ordinal, index + 1)
		}

		if alloc_result != nil {
			testing.expect_value(t, mem.free_bytes(alloc_result, allocator), runtime.Allocator_Error.None)
		}
		if nonzero_result != nil {
			testing.expect_value(t, mem.free_bytes(nonzero_result, allocator), runtime.Allocator_Error.None)
		}
		testing.expect_value(t, mem.free(resize_source, allocator), runtime.Allocator_Error.None)
		testing.expect_value(t, mem.free(resize_nonzero_source, allocator), runtime.Allocator_Error.None)
		testing.expect_value(t, state.live_count, 0)
	}
}

@(test)
test_observed_allocator_records_query_modes_by_ordinal :: proc(t: ^testing.T) {
	events: [4]Allocator_Event
	live: [1]Live_Allocation
	state: Observed_Allocator
	observed_allocator_init(&state, context.allocator, events[:], live[:])
	allocator := observed_allocator(&state)

	_ = mem.query_features(allocator)
	_ = mem.query_info(nil, allocator)
	testing.expect_value(t, state.event_count, 2)
	testing.expect_value(t, state.events[0].kind, Allocator_Event_Kind.Query_Features)
	testing.expect_value(t, state.events[0].kind_ordinal, 1)
	testing.expect_value(t, state.events[1].kind, Allocator_Event_Kind.Query_Info)
	testing.expect_value(t, state.events[1].kind_ordinal, 1)
}

@(test)
test_observed_allocator_clears_bulk_lifetime_and_marks_foreign_resize :: proc(t: ^testing.T) {
	buffer: [128]byte
	arena: mem.Arena
	mem.arena_init(&arena, buffer[:])
	events: [8]Allocator_Event
	live: [4]Live_Allocation
	state: Observed_Allocator
	observed_allocator_init(&state, mem.arena_allocator(&arena), events[:], live[:])
	allocator := observed_allocator(&state)

	_, err := mem.alloc_bytes(8, allocator = allocator)
	testing.expect_value(t, err, runtime.Allocator_Error.None)
	testing.expect_value(t, state.live_count, 1)
	testing.expect_value(t, mem.free_all(allocator), runtime.Allocator_Error.None)
	testing.expect_value(t, state.live_count, 0)

	outsider: [1]byte
	_, foreign_resize_err := mem.resize(
		raw_data(outsider[:]),
		1,
		2,
		allocator = allocator,
	)
	testing.expect_value(t, foreign_resize_err, runtime.Allocator_Error.Invalid_Pointer)
	testing.expect_value(t, state.foreign_resize_count, 1)
	testing.expect(t, state.events[2].foreign_memory)
	testing.expect_value(t, state.events[2].ordinal, 3)
}

@(test)
test_rejecting_allocator_detects_ambient_use :: proc(t: ^testing.T) {
	selected := context.allocator
	rejecting: Rejecting_Allocator
	context.allocator = rejecting_allocator(&rejecting)

	bytes, err := mem.alloc_bytes(8, allocator = selected)
	testing.expect_value(t, err, runtime.Allocator_Error.None)
	testing.expect_value(t, rejecting.call_count, 0)
	testing.expect_value(t, mem.free_bytes(bytes, selected), runtime.Allocator_Error.None)

	ambient_bytes, ambient_err := mem.alloc_bytes(8)
	testing.expect_value(t, len(ambient_bytes), 0)
	testing.expect_value(t, ambient_err, runtime.Allocator_Error.Out_Of_Memory)
	testing.expect_value(t, rejecting.call_count, 1)
	testing.expect_value(t, rejecting.allocation_attempt_count, 1)
}

@(test)
test_external_lifetime_allocators_report_or_reject_feature_queries :: proc(t: ^testing.T) {
	buffer: [256]byte
	arena: mem.Arena
	mem.arena_init(&arena, buffer[:])

	reported: External_Lifetime_Allocator
	external_lifetime_allocator_init(&reported, mem.arena_allocator(&arena), true)
	reported_allocator := external_lifetime_allocator(&reported)
	features := mem.query_features(reported_allocator)
	testing.expect(t, .Query_Features in features)
	testing.expect(t, .Alloc in features)
	testing.expect(t, .Free not_in features)

	bytes, err := mem.alloc_bytes(16, allocator = reported_allocator)
	testing.expect_value(t, err, runtime.Allocator_Error.None)
	testing.expect_value(t, mem.free_bytes(bytes, reported_allocator), runtime.Allocator_Error.Mode_Not_Implemented)
	testing.expect_value(t, reported.release_attempt_count, 1)
	testing.expect(t, arena.offset > 0)
	testing.expect_value(t, mem.free_all(reported_allocator), runtime.Allocator_Error.None)
	testing.expect_value(t, arena.offset, 0)

	unsupported: External_Lifetime_Allocator
	external_lifetime_allocator_init(&unsupported, mem.arena_allocator(&arena), false)
	unsupported_allocator := external_lifetime_allocator(&unsupported)
	unsupported_features: runtime.Allocator_Mode_Set
	_, query_err := unsupported_allocator.procedure(
		unsupported_allocator.data,
		.Query_Features,
		0,
		0,
		&unsupported_features,
		0,
	)
	testing.expect_value(t, query_err, runtime.Allocator_Error.Mode_Not_Implemented)
	testing.expect_value(t, unsupported_features, runtime.Allocator_Mode_Set(nil))

	unsupported_bytes, unsupported_err := mem.alloc_bytes(8, allocator = unsupported_allocator)
	testing.expect_value(t, unsupported_err, runtime.Allocator_Error.None)
	testing.expect_value(
		t,
		mem.free_bytes(unsupported_bytes, unsupported_allocator),
		runtime.Allocator_Error.Mode_Not_Implemented,
	)
	testing.expect_value(t, unsupported.release_attempt_count, 1)
	mem.arena_free_all(&arena)

	rejecting: Rejecting_Allocator
	constrained: External_Lifetime_Allocator
	external_lifetime_allocator_init(&constrained, rejecting_allocator(&rejecting), true)
	constrained_features := mem.query_features(external_lifetime_allocator(&constrained))
	testing.expect(t, .Query_Features in constrained_features)
	testing.expect(t, .Alloc not_in constrained_features)
}

package codec_registry_test

import "base:runtime"
import "core:mem"
import "core:testing"
import "core:thread"
import toml "../.."
import test_support "../support"

Sample :: struct {
	value: i32,
}

Codec_Type_00 :: distinct i32
Codec_Type_01 :: distinct i32
Codec_Type_02 :: distinct i32
Codec_Type_03 :: distinct i32
Codec_Type_04 :: distinct i32
Codec_Type_05 :: distinct i32
Codec_Type_06 :: distinct i32
Codec_Type_07 :: distinct i32
Codec_Type_08 :: distinct i32
Codec_Type_09 :: distinct i32
Codec_Type_10 :: distinct i32
Codec_Type_11 :: distinct i32
Codec_Type_12 :: distinct i32
Codec_Type_13 :: distinct i32
Codec_Type_14 :: distinct i32
Codec_Type_15 :: distinct i32
Codec_Type_16 :: distinct i32
Codec_Type_17 :: distinct i32
Codec_Type_18 :: distinct i32
Codec_Type_19 :: distinct i32

codec_type_ids :: proc() -> [20]typeid {
	return {
		typeid_of(Codec_Type_00), typeid_of(Codec_Type_01),
		typeid_of(Codec_Type_02), typeid_of(Codec_Type_03),
		typeid_of(Codec_Type_04), typeid_of(Codec_Type_05),
		typeid_of(Codec_Type_06), typeid_of(Codec_Type_07),
		typeid_of(Codec_Type_08), typeid_of(Codec_Type_09),
		typeid_of(Codec_Type_10), typeid_of(Codec_Type_11),
		typeid_of(Codec_Type_12), typeid_of(Codec_Type_13),
		typeid_of(Codec_Type_14), typeid_of(Codec_Type_15),
		typeid_of(Codec_Type_16), typeid_of(Codec_Type_17),
		typeid_of(Codec_Type_18), typeid_of(Codec_Type_19),
	}
}

marshal_sample :: proc(
	source: any,
	user_data: rawptr,
	allocator: mem.Allocator,
	loc: runtime.Source_Code_Location,
) -> (toml.Value, toml.Codec_Callback_Error) {
	_, _, _, _ = source, user_data, allocator, loc
	return toml.Value(toml.Integer(0)), nil
}

unmarshal_sample :: proc(
	source: ^toml.Value,
	destination: any,
	user_data: rawptr,
	allocator: mem.Allocator,
	loc: runtime.Source_Code_Location,
) -> toml.Codec_Callback_Error {
	_, _, _, _, _ = source, destination, user_data, allocator, loc
	return nil
}

allocator_equal :: proc(a, b: mem.Allocator) -> bool {
	return a.procedure == b.procedure && a.data == b.data
}

registry_is_zero :: proc(registry: toml.Codec_Registry) -> bool {
	return len(registry.marshalers) == 0 && cap(registry.marshalers) == 0 &&
	       registry.marshalers.allocator.procedure == nil &&
	       registry.marshalers.allocator.data == nil &&
	       len(registry.unmarshalers) == 0 && cap(registry.unmarshalers) == 0 &&
	       registry.unmarshalers.allocator.procedure == nil &&
	       registry.unmarshalers.allocator.data == nil &&
	       registry.allocator.procedure == nil && registry.allocator.data == nil &&
	       !registry.initialized
}

expect_registry_data_error :: proc(
	t: ^testing.T,
	err: toml.Codec_Registry_Error,
	expected: toml.Codec_Registry_Data_Error,
) {
	actual, ok := err.(toml.Codec_Registry_Data_Error)
	testing.expect(t, ok)
	if ok {
		testing.expect_value(t, actual, expected)
	}
}

Frozen_Read_State :: struct {
	registry: ^toml.Codec_Registry,
	id: typeid,
	expected_user_data: rawptr,
	success: bool,
}

frozen_read_worker :: proc(data: rawptr) {
	state := (^Frozen_Read_State)(data)
	state.success = true
	for _ in 0 ..< 100_000 {
		marshaler, marshal_ok := state.registry.marshalers[state.id]
		unmarshaler, unmarshal_ok := state.registry.unmarshalers[state.id]
		if !marshal_ok || !unmarshal_ok ||
		   marshaler.procedure != marshal_sample ||
		   unmarshaler.procedure != unmarshal_sample ||
		   marshaler.user_data != state.expected_user_data ||
		   unmarshaler.user_data != state.expected_user_data {
			state.success = false
			return
		}
	}
}

@(test)
test_init_retains_selected_allocator_and_produces_initialized_empty_maps :: proc(t: ^testing.T) {
	backing := context.allocator
	events: [8]test_support.Allocator_Event
	live: [2]test_support.Live_Allocation
	observed: test_support.Observed_Allocator
	test_support.observed_allocator_init(&observed, backing, events[:], live[:])
	selected := test_support.observed_allocator(&observed)
	rejecting: test_support.Rejecting_Allocator
	context.allocator = test_support.rejecting_allocator(&rejecting)

	registry, err := toml.init_codec_registry(selected)
	context.allocator = backing

	testing.expect(t, err == nil)
	testing.expect(t, registry.initialized)
	testing.expect(t, allocator_equal(registry.allocator, selected))
	testing.expect(t, allocator_equal(registry.marshalers.allocator, selected))
	testing.expect(t, allocator_equal(registry.unmarshalers.allocator, selected))
	testing.expect_value(t, len(registry.marshalers), 0)
	testing.expect_value(t, cap(registry.marshalers), 0)
	testing.expect_value(t, len(registry.unmarshalers), 0)
	testing.expect_value(t, cap(registry.unmarshalers), 0)
	testing.expect_value(t, observed.allocation_request_count, 0)
	testing.expect_value(t, rejecting.call_count, 0)

	toml.destroy_codec_registry(&registry)
	testing.expect(t, registry_is_zero(registry))
}

@(test)
test_init_rejects_a_nil_allocator :: proc(t: ^testing.T) {
	registry, err := toml.init_codec_registry(mem.Allocator{})
	expect_registry_data_error(t, err, .Invalid_Allocator)
	testing.expect(t, registry_is_zero(registry))
}

@(test)
test_directional_registration_stores_exact_callbacks_and_user_data :: proc(t: ^testing.T) {
	registry, init_error := toml.init_codec_registry()
	testing.expect(t, init_error == nil)
	defer toml.destroy_codec_registry(&registry)

	marshal_state := i32(17)
	unmarshal_state := i32(29)
	marshaler := toml.Codec_Marshaler{
		procedure = marshal_sample,
		user_data = &marshal_state,
	}
	unmarshaler := toml.Codec_Unmarshaler{
		procedure = unmarshal_sample,
		user_data = &unmarshal_state,
	}
	id := typeid_of(Sample)

	testing.expect(t, toml.register_marshaler(&registry, id, marshaler) == nil)
	_, unmarshal_absent := registry.unmarshalers[id]
	testing.expect(t, !unmarshal_absent)
	testing.expect(t, toml.register_unmarshaler(&registry, id, unmarshaler) == nil)

	stored_marshaler, marshal_ok := registry.marshalers[id]
	stored_unmarshaler, unmarshal_ok := registry.unmarshalers[id]
	testing.expect(t, marshal_ok)
	testing.expect(t, unmarshal_ok)
	testing.expect(t, stored_marshaler.procedure == marshal_sample)
	testing.expect(t, stored_marshaler.user_data == &marshal_state)
	testing.expect(t, stored_unmarshaler.procedure == unmarshal_sample)
	testing.expect(t, stored_unmarshaler.user_data == &unmarshal_state)
	_, base_type_present := registry.marshalers[typeid_of(i32)]
	testing.expect(t, !base_type_present)

	expect_registry_data_error(
		t,
		toml.register_marshaler(&registry, id, marshaler),
		.Duplicate_Codec,
	)
	expect_registry_data_error(
		t,
		toml.register_unmarshaler(&registry, id, unmarshaler),
		.Duplicate_Codec,
	)
	testing.expect_value(t, len(registry.marshalers), 1)
	testing.expect_value(t, len(registry.unmarshalers), 1)
}

@(test)
test_registration_rejects_invalid_registry_typeid_and_callback :: proc(t: ^testing.T) {
	id := typeid_of(Sample)
	marshaler := toml.Codec_Marshaler{procedure = marshal_sample}
	unmarshaler := toml.Codec_Unmarshaler{procedure = unmarshal_sample}

	expect_registry_data_error(
		t,
		toml.register_marshaler(nil, id, marshaler),
		.Invalid_Registry,
	)
	zero_registry: toml.Codec_Registry
	expect_registry_data_error(
		t,
		toml.register_unmarshaler(&zero_registry, id, unmarshaler),
		.Invalid_Registry,
	)

	registry, init_error := toml.init_codec_registry()
	testing.expect(t, init_error == nil)
	defer toml.destroy_codec_registry(&registry)
	zero_id: typeid
	expect_registry_data_error(
		t,
		toml.register_marshaler(&registry, zero_id, marshaler),
		.Invalid_Type_ID,
	)
	expect_registry_data_error(
		t,
		toml.register_unmarshaler(&registry, zero_id, unmarshaler),
		.Invalid_Type_ID,
	)
	expect_registry_data_error(
		t,
		toml.register_marshaler(&registry, id, {}),
		.Nil_Callback,
	)
	expect_registry_data_error(
		t,
		toml.register_unmarshaler(&registry, id, {}),
		.Nil_Callback,
	)
	testing.expect_value(t, len(registry.marshalers), 0)
	testing.expect_value(t, len(registry.unmarshalers), 0)

	registry.initialized = false
	expect_registry_data_error(
		t,
		toml.register_marshaler(&registry, id, marshaler),
		.Invalid_Registry,
	)
	registry.initialized = true
	registry.marshalers.allocator = {}
	expect_registry_data_error(
		t,
		toml.register_marshaler(&registry, id, marshaler),
		.Invalid_Registry,
	)
	registry.marshalers.allocator = registry.allocator
}

@(test)
test_growth_allocation_failures_preserve_every_prior_entry_without_leaks :: proc(t: ^testing.T) {
	ids := codec_type_ids()
	backing := context.allocator

	baseline_events: [64]test_support.Allocator_Event
	baseline_live: [8]test_support.Live_Allocation
	baseline: test_support.Observed_Allocator
	test_support.observed_allocator_init(
		&baseline,
		backing,
		baseline_events[:],
		baseline_live[:],
	)
	baseline_allocator := test_support.observed_allocator(&baseline)
	baseline_registry, baseline_init_error := toml.init_codec_registry(baseline_allocator)
	assert(baseline_init_error == nil)
	for id in ids {
		assert(toml.register_marshaler(
			&baseline_registry,
			id,
			{procedure = marshal_sample},
		) == nil)
	}
	allocation_count := baseline.allocation_request_count
	testing.expect(t, allocation_count >= 2)
	toml.destroy_codec_registry(&baseline_registry)
	testing.expect_value(t, baseline.live_count, 0)

	for fail_at in 1 ..= allocation_count {
		events: [64]test_support.Allocator_Event
		live: [8]test_support.Live_Allocation
		state: test_support.Observed_Allocator
		test_support.observed_allocator_init(&state, backing, events[:], live[:])
		state.fail_at_allocation = fail_at
		selected := test_support.observed_allocator(&state)
		registry, init_error := toml.init_codec_registry(selected)
		assert(init_error == nil)

		registered_count := 0
		failure: toml.Codec_Registry_Error
		for id in ids {
			failure = toml.register_marshaler(
				&registry,
				id,
				{procedure = marshal_sample},
			)
			if failure != nil {
				break
			}
			registered_count += 1
		}
		allocator_error, ok := failure.(runtime.Allocator_Error)
		testing.expect(t, ok)
		if ok {
			testing.expect_value(t, allocator_error, runtime.Allocator_Error.Out_Of_Memory)
		}
		testing.expect_value(t, len(registry.marshalers), registered_count)
		for id in ids[:registered_count] {
			stored, found := registry.marshalers[id]
			testing.expect(t, found)
			if found {
				testing.expect(t, stored.procedure == marshal_sample)
			}
		}

		toml.destroy_codec_registry(&registry)
		testing.expect(t, registry_is_zero(registry))
		testing.expect_value(t, state.live_count, 0)
		testing.expect_value(t, state.foreign_release_count, 0)
	}

	events: [64]test_support.Allocator_Event
	live: [8]test_support.Live_Allocation
	state: test_support.Observed_Allocator
	test_support.observed_allocator_init(&state, backing, events[:], live[:])
	state.fail_at_allocation = allocation_count + 1
	selected := test_support.observed_allocator(&state)
	registry, init_error := toml.init_codec_registry(selected)
	assert(init_error == nil)
	for id in ids {
		testing.expect(t, toml.register_marshaler(
			&registry,
			id,
			{procedure = marshal_sample},
		) == nil)
	}
	testing.expect_value(t, len(registry.marshalers), len(ids))
	toml.destroy_codec_registry(&registry)
	testing.expect_value(t, state.live_count, 0)
}

@(test)
test_unmarshaler_growth_failure_preserves_prior_entries_without_leaks :: proc(t: ^testing.T) {
	ids := codec_type_ids()
	backing := context.allocator
	events: [64]test_support.Allocator_Event
	live: [8]test_support.Live_Allocation
	state: test_support.Observed_Allocator
	test_support.observed_allocator_init(&state, backing, events[:], live[:])
	state.fail_at_allocation = 2
	selected := test_support.observed_allocator(&state)
	registry, init_error := toml.init_codec_registry(selected)
	assert(init_error == nil)

	failure: toml.Codec_Registry_Error
	registered_count := 0
	for id in ids {
		failure = toml.register_unmarshaler(
			&registry,
			id,
			{procedure = unmarshal_sample},
		)
		if failure != nil {
			break
		}
		registered_count += 1
	}
	allocator_error, ok := failure.(runtime.Allocator_Error)
	testing.expect(t, ok)
	if ok {
		testing.expect_value(t, allocator_error, runtime.Allocator_Error.Out_Of_Memory)
	}
	testing.expect(t, registered_count > 0)
	testing.expect_value(t, len(registry.unmarshalers), registered_count)
	for id in ids[:registered_count] {
		stored, found := registry.unmarshalers[id]
		testing.expect(t, found)
		if found {
			testing.expect(t, stored.procedure == unmarshal_sample)
		}
	}

	toml.destroy_codec_registry(&registry)
	testing.expect_value(t, state.live_count, 0)
	testing.expect_value(t, state.foreign_release_count, 0)
}

@(test)
test_growth_propagates_the_allocator_error_exactly :: proc(t: ^testing.T) {
	ids := codec_type_ids()
	backing := context.allocator
	events: [64]test_support.Allocator_Event
	live: [8]test_support.Live_Allocation
	state: test_support.Observed_Allocator
	test_support.observed_allocator_init(&state, backing, events[:], live[:])
	state.fail_at_allocation = 2
	state.failure_error = .Mode_Not_Implemented
	selected := test_support.observed_allocator(&state)
	registry, init_error := toml.init_codec_registry(selected)
	assert(init_error == nil)

	failure: toml.Codec_Registry_Error
	registered_count := 0
	for id in ids {
		failure = toml.register_marshaler(
			&registry,
			id,
			{procedure = marshal_sample},
		)
		if failure != nil {
			break
		}
		registered_count += 1
	}
	allocator_error, ok := failure.(runtime.Allocator_Error)
	testing.expect(t, ok)
	if ok {
		testing.expect_value(t, allocator_error, runtime.Allocator_Error.Mode_Not_Implemented)
	}
	testing.expect(t, registered_count > 0)
	testing.expect_value(t, len(registry.marshalers), registered_count)
	for id in ids[:registered_count] {
		_, found := registry.marshalers[id]
		testing.expect(t, found)
	}

	toml.destroy_codec_registry(&registry)
	testing.expect_value(t, state.live_count, 0)
}

@(test)
test_destroy_releases_both_maps_zeros_owner_and_is_idempotent :: proc(t: ^testing.T) {
	backing := context.allocator
	events: [32]test_support.Allocator_Event
	live: [4]test_support.Live_Allocation
	state: test_support.Observed_Allocator
	test_support.observed_allocator_init(&state, backing, events[:], live[:])
	selected := test_support.observed_allocator(&state)
	registry, init_error := toml.init_codec_registry(selected)
	assert(init_error == nil)
	rejecting: test_support.Rejecting_Allocator
	context.allocator = test_support.rejecting_allocator(&rejecting)
	assert(toml.register_marshaler(
		&registry,
		typeid_of(Sample),
		{procedure = marshal_sample},
	) == nil)
	assert(toml.register_unmarshaler(
		&registry,
		typeid_of(Sample),
		{procedure = unmarshal_sample},
	) == nil)
	live_before_destroy := state.live_count
	toml.destroy_codec_registry(&registry)
	context.allocator = backing

	testing.expect_value(t, live_before_destroy, 2)
	testing.expect(t, registry_is_zero(registry))
	testing.expect_value(t, state.live_count, 0)
	testing.expect_value(t, state.release_count, 2)
	testing.expect_value(t, rejecting.call_count, 0)
	calls_after_first_destroy := state.event_count
	toml.destroy_codec_registry(&registry)
	toml.destroy_codec_registry(nil)
	testing.expect_value(t, state.event_count, calls_after_first_destroy)
}

// Direct lookup through the frozen public maps is the approved lifecycle seam.
// Concurrent typed-call coverage belongs to the later typed codec tickets.
@(test)
test_frozen_registry_supports_concurrent_read_only_lookup :: proc(t: ^testing.T) {
	registry, init_error := toml.init_codec_registry()
	assert(init_error == nil)
	user_state := i32(42)
	id := typeid_of(Sample)
	assert(toml.register_marshaler(
		&registry,
		id,
		{procedure = marshal_sample, user_data = &user_state},
	) == nil)
	assert(toml.register_unmarshaler(
		&registry,
		id,
		{procedure = unmarshal_sample, user_data = &user_state},
	) == nil)

	THREAD_COUNT :: 4
	states: [THREAD_COUNT]Frozen_Read_State
	threads: [THREAD_COUNT]^thread.Thread
	for index in 0 ..< THREAD_COUNT {
		states[index] = {
			registry = &registry,
			id = id,
			expected_user_data = &user_state,
		}
		threads[index] = thread.create_and_start_with_data(
			&states[index],
			frozen_read_worker,
		)
		testing.expect(t, threads[index] != nil)
	}
	for worker in threads {
		if worker != nil {
			thread.destroy(worker)
		}
	}
	for state in states {
		testing.expect(t, state.success)
	}

	toml.destroy_codec_registry(&registry)
}

@(test)
test_destroy_logically_ends_external_lifetime_storage_without_global_release :: proc(t: ^testing.T) {
	buffer: [16 * 1024]byte
	arena: mem.Arena
	mem.arena_init(&arena, buffer[:])
	defer mem.arena_free_all(&arena)

	reporting_modes := [2]bool{true, false}
	for report_features in reporting_modes {
		state: test_support.External_Lifetime_Allocator
		test_support.external_lifetime_allocator_init(
			&state,
			mem.arena_allocator(&arena),
			report_features,
		)
		selected := test_support.external_lifetime_allocator(&state)
		registry, init_error := toml.init_codec_registry(selected)
		assert(init_error == nil)
		assert(toml.register_marshaler(
			&registry,
			typeid_of(Sample),
			{procedure = marshal_sample},
		) == nil)
		assert(toml.register_unmarshaler(
			&registry,
			typeid_of(Sample),
			{procedure = unmarshal_sample},
		) == nil)

		toml.destroy_codec_registry(&registry)
		testing.expect(t, registry_is_zero(registry))
		testing.expect_value(t, state.free_all_count, 0)
		expected_release_attempts := 0 if report_features else 1
		testing.expect_value(t, state.release_attempt_count, expected_release_attempts)
	}
}

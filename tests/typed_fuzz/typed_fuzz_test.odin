package typed_fuzz_test

import "core:testing"
import test_support "../support"

TYPED_GENERATED_CASE_COUNT :: 512

Replay_Fixture :: struct {
	name:     string,
	seed:     u64,
	artifact: []byte,
}

REPLAY_FIXTURES := [?]Replay_Fixture{
	{"empty-artifact-unknown-preflight", 123456789, {}},
	{"codec-round-trip-order", 123456789, {0, 0x26, 1, 2, 3, 4}},
	{"unknown-field-preflight", 123456789, {1}},
	{"callback-transaction", 123456789, {2}},
	{"active-cycle-after-codec", 123456789, {3}},
	{"marshal-only-any", 123456789, {4, 99}},
	{"writer-permission-prefix", 123456789, {5, 1, 2, 2, 1}},
	{"marshal-fail-at-n", 123456789, {6, 9, 8, 7, 6, 5}},
	{"unmarshal-fail-at-n-cleanup", 123456789, {7, 9, 8, 7, 6, 5, 4}},
}

@(test)
test_generated_typed_and_codec_properties_are_replayable :: proc(t: ^testing.T) {
	random := test_support.replay_random_from_test(t, "typed-codec-properties")
	input: [32]byte
	for case_index in 0..<TYPED_GENERATED_CASE_COUNT {
		_ = test_support.replay_read(&random, input[:])
		input[0] = byte(case_index%8)
		coverage_typed_codec_target(input[:])
	}
}

@(test)
test_typed_codec_minimized_replay_fixtures_remain_public_api_regressions :: proc(t: ^testing.T) {
	_ = test_support.replay_random_from_test(t, "typed-codec-regression-fixtures")
	for fixture in REPLAY_FIXTURES {
		testing.expect(t, fixture.name != "")
		testing.expect_value(t, fixture.seed, u64(123456789))
		coverage_typed_codec_target(fixture.artifact)
	}
}

@(test)
test_complete_allocation_sweeps_preserve_exact_errors_and_cleanup :: proc(t: ^testing.T) {
	_ = test_support.replay_random_from_test(t, "typed-codec-allocation-sweeps")
	// Each workflow keeps one fixed generated shape while sweeping every
	// one-based allocation request measured by its successful baseline.
	input := [8]byte{6, 1, 2, 3, 4, 5, 6, 7}

	marshal_count := measure_marshal_allocation_count(input[:])
	for fail_at in 1..=marshal_count {
		run_marshal_allocation_at(input[:], fail_at, true)
	}
	run_marshal_allocation_at(input[:], marshal_count+1, false)

	writer_count := measure_writer_allocation_count(input[:])
	for fail_at in 1..=writer_count {
		run_writer_allocation_at(input[:], fail_at, true)
	}
	run_writer_allocation_at(input[:], writer_count+1, false)

	unmarshal_count := measure_unmarshal_allocation_count(input[:])
	parse_count := measure_unmarshal_parse_allocation_count(input[:])
	testing.expect(t, parse_count < unmarshal_count)
	saw_cleanable_partial_install := false
	for fail_at in 1..=unmarshal_count {
		saw_cleanable_partial_install = run_unmarshal_allocation_at(
			input[:], fail_at, parse_count, true,
		) || saw_cleanable_partial_install
	}
	run_unmarshal_allocation_at(
		input[:], unmarshal_count+1, parse_count, false,
	)
	testing.expect(t, saw_cleanable_partial_install)
}

@(test)
test_codec_writer_fault_matrix_covers_every_call_and_result_class :: proc(t: ^testing.T) {
	_ = test_support.replay_random_from_test(t, "typed-codec-writer-matrix")
	input := [8]byte{5, 9, 8, 7, 6, 5, 4, 3}
	run_writer_fault_matrix(input[:])
}

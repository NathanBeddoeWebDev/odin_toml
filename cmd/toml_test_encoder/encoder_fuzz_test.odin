package main

import "core:fmt"
import "core:strings"
import "core:testing"
import test_support "../../tests/support"

ADAPTER_ARBITRARY_CASE_COUNT :: 4_096
ADAPTER_PROTOCOL_MUTATION_CASE_COUNT :: 1_024

@(test)
test_encoder_adapter_arbitrary_protocol_target_is_replayable_and_leak_free :: proc(t: ^testing.T) {
	random := test_support.replay_random_from_test(t, "encoder-adapter-arbitrary-protocol")
	storage: [256]byte
	for _ in 0..<ADAPTER_ARBITRARY_CASE_COUNT {
		count := test_support.replay_int_max(&random, len(storage)+1)
		_ = test_support.replay_read(&random, storage[:count])
		run_encoder_adapter_coverage_target(storage[:count])
	}
}

@(test)
test_encoder_adapter_mutated_protocol_target_is_replayable_and_leak_free :: proc(t: ^testing.T) {
	seeds := [?]string{
		`{}`,
		`{"name":{"type":"string","value":"odin"}}`,
		`{"number":{"type":"integer","value":"42"}}`,
		`{"items":[{"type":"bool","value":"true"}]}`,
		`{"nested":{"table":{"type":"date-local","value":"2024-02-29"}}}`,
	}
	random := test_support.replay_random_from_test(t, "encoder-adapter-protocol-mutations")
	storage: [1024]byte
	for case_index in 0..<ADAPTER_PROTOCOL_MUTATION_CASE_COUNT {
		mutated := mutate_protocol_seed(
			&random,
			seeds[case_index%len(seeds)],
			storage[:],
		)
		run_encoder_adapter_coverage_target(mutated)
	}
}

@(test)
test_encoder_adapter_large_accepted_artifact_is_not_limited_by_harness_storage :: proc(t: ^testing.T) {
	_ = t
	payload, payload_error := strings.repeat("x", 40_000)
	assert(payload_error == nil)
	defer delete(payload)
	input := fmt.aprintf(`{{"value":{{"type":"string","value":"%s"}}}}`, payload)
	defer delete(input)
	run_encoder_adapter_coverage_target(transmute([]byte)input)
}

@(test)
test_encoder_adapter_minimized_protocol_regressions_remain_rejected_without_output :: proc(t: ^testing.T) {
	fixtures := [?]string{
		`{`,
		`{} {}`,
		`[]`,
		`{"a":{"type":"integer","value":"1"},"a":{"type":"integer","value":"2"}}`,
		`{"":{"type":"string","value":"a"},"":{"type":"string","value":"b"}}`,
		`{"a":{"type":"integer","value":1}}`,
		`{"a":{"type":"unknown","value":"x"}}`,
	}
	for fixture in fixtures {
		run_encoder_adapter_coverage_target(transmute([]byte)fixture)
	}
}

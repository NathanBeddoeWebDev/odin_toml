package main

import "core:testing"
import test_support "../../tests/support"

DECODER_ADAPTER_ARBITRARY_CASE_COUNT :: 4_096

@(test)
test_decoder_adapter_arbitrary_input_target_is_replayable_and_leak_free :: proc(t: ^testing.T) {
	random := test_support.replay_random_from_test(t, "decoder-adapter-arbitrary-input")
	storage: [256]byte
	for _ in 0..<DECODER_ADAPTER_ARBITRARY_CASE_COUNT {
		count := test_support.replay_int_max(&random, len(storage)+1)
		_ = test_support.replay_read(&random, storage[:count])
		run_decoder_adapter_fuzz_target(t, storage[:count])
	}
}

@(test)
test_decoder_adapter_regression_inputs_remain_deterministic :: proc(t: ^testing.T) {
	fixtures := [?]string{
		"",
		"# comment\n",
		`value = "α🪶"` + "\n",
		"value = truex\n",
		"[a]\n[a]\n",
	}
	for fixture in fixtures {
		run_decoder_adapter_fuzz_target(t, transmute([]byte)fixture)
	}
	invalid_utf8 := [?]byte{0xc0, 0x80}
	run_decoder_adapter_fuzz_target(t, invalid_utf8[:])
}

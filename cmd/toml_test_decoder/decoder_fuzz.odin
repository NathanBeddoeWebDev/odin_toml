package main

import json "core:encoding/json"
import "core:testing"
import test_support "../../tests/support"

run_decoder_adapter_fuzz_target :: proc(t: ^testing.T, input: []byte) {
	live: [1024]test_support.Live_Allocation
	observed: test_support.Observed_Allocator
	backing := context.allocator
	test_support.observed_allocator_init(&observed, backing, nil, live[:])
	selected := test_support.observed_allocator(&observed)
	calls: [1024]test_support.Scripted_Writer_Call
	bytes: [32*1024]byte
	writer_state: test_support.Scripted_Writer
	test_support.scripted_writer_init(&writer_state, nil, calls[:], bytes[:])

	context.allocator = selected
	err := decode_to_writer(input, test_support.scripted_writer(&writer_state))
	context.allocator = backing

	testing.expect_value(t, observed.live_count, 0)
	testing.expect_value(t, observed.foreign_release_count, 0)
	testing.expect_value(t, observed.live_overflow_count, 0)
	testing.expect_value(t, writer_state.dropped_call_count, 0)
	testing.expect_value(t, writer_state.dropped_byte_count, 0)
	if err != nil {
		kind, adapter_error := err.(Adapter_Error_Kind)
		testing.expect(t, adapter_error)
		if adapter_error {
			testing.expect_value(t, kind, Adapter_Error_Kind.Malformed_Input)
		}
		testing.expect_value(t, writer_state.write_count, 0)
		return
	}

	output := bytes[:writer_state.byte_count]
	testing.expect(t, json.is_valid(output, .JSON, true))
}

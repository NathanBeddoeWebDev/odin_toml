package main

import json "core:encoding/json"
import "core:io"
import "core:testing"
import test_support "../../tests/support"

Fuzz_Counting_Writer :: struct {
	byte_count: int,
}

fuzz_counting_writer :: proc(state: ^Fuzz_Counting_Writer) -> io.Writer {
	return {procedure = fuzz_counting_writer_proc, data = state}
}

fuzz_counting_writer_proc :: proc(
	stream_data: rawptr,
	mode: io.Stream_Mode,
	p: []byte,
	offset: i64,
	whence: io.Seek_From,
) -> (n: i64, err: io.Error) {
	_, _ = offset, whence
	state := (^Fuzz_Counting_Writer)(stream_data)
	#partial switch mode {
	case .Write:
		assert(len(p) <= max(int)-state.byte_count)
		state.byte_count += len(p)
		return i64(len(p)), nil
	case .Query:
		return transmute(i64)(io.Stream_Mode_Set{.Write, .Query}), nil
	case:
		return 0, .Unsupported
	}
}

Fuzz_Buffer_Writer :: struct {
	bytes:  []byte,
	cursor: int,
}

fuzz_buffer_writer :: proc(state: ^Fuzz_Buffer_Writer) -> io.Writer {
	return {procedure = fuzz_buffer_writer_proc, data = state}
}

fuzz_buffer_writer_proc :: proc(
	stream_data: rawptr,
	mode: io.Stream_Mode,
	p: []byte,
	offset: i64,
	whence: io.Seek_From,
) -> (n: i64, err: io.Error) {
	_, _ = offset, whence
	state := (^Fuzz_Buffer_Writer)(stream_data)
	#partial switch mode {
	case .Write:
		assert(len(p) <= len(state.bytes)-state.cursor)
		copy(state.bytes[state.cursor:], p)
		state.cursor += len(p)
		return i64(len(p)), nil
	case .Query:
		return transmute(i64)(io.Stream_Mode_Set{.Write, .Query}), nil
	case:
		return 0, .Unsupported
	}
}

run_decoder_adapter_coverage_target :: proc(input: []byte) {
	live: [1024]test_support.Live_Allocation
	observed: test_support.Observed_Allocator
	backing := context.allocator
	test_support.observed_allocator_init(&observed, backing, nil, live[:])
	selected := test_support.observed_allocator(&observed)
	// The adapter can emit more small writes than input bytes. Count first, then
	// capture exactly that successful JSON output rather than imposing a fuzz cap.
	counting_state: Fuzz_Counting_Writer

	context.allocator = selected
	err := decode_to_writer(input, fuzz_counting_writer(&counting_state))
	context.allocator = backing

	assert(observed.live_count == 0)
	assert(observed.foreign_release_count == 0)
	assert(observed.live_overflow_count == 0)
	if err != nil {
		kind, adapter_error := err.(Adapter_Error_Kind)
		assert(adapter_error)
		assert(kind == Adapter_Error_Kind.Malformed_Input)
		assert(counting_state.byte_count == 0)
		return
	}

	output, allocation_error := make([]byte, counting_state.byte_count, backing)
	assert(allocation_error == nil)
	defer delete(output, backing)
	buffer_state := Fuzz_Buffer_Writer{bytes = output}

	context.allocator = selected
	err = decode_to_writer(input, fuzz_buffer_writer(&buffer_state))
	context.allocator = backing
	assert(err == nil)
	assert(buffer_state.cursor == len(output))
	assert(observed.live_count == 0)
	assert(observed.foreign_release_count == 0)
	assert(observed.live_overflow_count == 0)
	assert(json.is_valid(output, .JSON, true))
}

run_decoder_adapter_fuzz_target :: proc(t: ^testing.T, input: []byte) {
	_ = t
	run_decoder_adapter_coverage_target(input)
}

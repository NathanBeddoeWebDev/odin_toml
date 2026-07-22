package main

import "core:io"
import toml "../.."
import test_support "../../tests/support"

mutate_protocol_seed :: proc(
	random: ^test_support.Replay_Random,
	seed: string,
	storage: []byte,
) -> []byte {
	operation := test_support.replay_int_max(random, 4)
	position := 0
	if len(seed) > 0 {
		position = test_support.replay_int_max(random, len(seed)+1)
	}
	mutation := byte(test_support.replay_int_max(random, 256))

	switch operation {
	case 0:
		count := copy(storage, transmute([]byte)seed)
		if count > 0 {
			storage[min(position, count-1)] = mutation
		}
		return storage[:count]
	case 1:
		count := copy(storage, transmute([]byte)seed[:position])
		if count < len(storage) {
			storage[count] = mutation
			count += 1
		}
		count += copy(storage[count:], transmute([]byte)seed[position:])
		return storage[:count]
	case 2:
		count := copy(storage, transmute([]byte)seed[:position])
		if position < len(seed) {
			count += copy(storage[count:], transmute([]byte)seed[position+1:])
		}
		return storage[:count]
	case 3:
		count := copy(storage, transmute([]byte)seed[:position])
		return storage[:count]
	}
	unreachable()
}

run_encoder_adapter_coverage_target :: proc(input: []byte) {
	if len(input) > (max(int)-1)/2 {
		err := encode_to_writer(input, io.Writer{})
		_, adapter_error := err.(Adapter_Error_Kind)
		assert(adapter_error)
		return
	}
	backing := context.allocator
	capacity := max(1024, len(input)*2+1)
	live, live_error := make([]test_support.Live_Allocation, capacity, backing)
	assert(live_error == nil)
	defer delete(live, backing)
	calls, calls_error := make([]test_support.Scripted_Writer_Call, capacity, backing)
	assert(calls_error == nil)
	defer delete(calls, backing)
	bytes, bytes_error := make([]byte, capacity, backing)
	assert(bytes_error == nil)
	defer delete(bytes, backing)

	observed: test_support.Observed_Allocator
	test_support.observed_allocator_init(&observed, backing, nil, live)
	selected := test_support.observed_allocator(&observed)
	writer_state: test_support.Scripted_Writer
	test_support.scripted_writer_init(&writer_state, nil, calls, bytes)

	context.allocator = selected
	err := encode_to_writer(input, test_support.scripted_writer(&writer_state))
	context.allocator = backing
	assert(observed.live_count == 0)
	assert(observed.foreign_release_count == 0)
	assert(observed.live_overflow_count == 0)
	assert(writer_state.dropped_call_count == 0)
	assert(writer_state.dropped_byte_count == 0)
	if err != nil {
		_, adapter_error := err.(Adapter_Error_Kind)
		assert(adapter_error)
		assert(writer_state.write_count == 0)
		return
	}

	output := bytes[:writer_state.byte_count]
	doc, parse_error := toml.parse_bytes(output)
	assert(parse_error == nil)
	canonical, unparse_error := toml.unparse(&doc)
	assert(unparse_error == nil)
	assert(canonical == string(output))
	delete(canonical)
	toml.destroy_document(&doc)
}

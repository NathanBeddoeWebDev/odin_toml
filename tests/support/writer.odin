package test_support

import "core:io"

Scripted_Write_Count_Kind :: enum u8 {
	Exact,
	Full,
	Negative,
	Past_End,
}

// Scripted_Write can represent every writer result class: Exact covers every
// count in [0, len(input)], while Negative and Past_End cover invalid counts.
// Any io.Error can be paired with any count class.
Scripted_Write :: struct {
	count_kind: Scripted_Write_Count_Kind,
	count:      i64,
	error:      io.Error,
}

// Scripted_Writer_Call records every invocation of the stream procedure. Write
// calls additionally retain their write ordinal, result, and requested bytes.
Scripted_Writer_Call :: struct {
	ordinal:         int,
	mode:            io.Stream_Mode,
	write_ordinal:   int,
	requested_count: int,
	returned_count:  i64,
	error:           io.Error,
	byte_offset:     int,
	byte_count:      int,
}

requested_bytes :: proc(call: Scripted_Writer_Call, storage: []byte) -> []byte {
	if call.byte_offset < 0 || call.byte_count < 0 ||
	   call.byte_offset + call.byte_count > len(storage) {
		return nil
	}
	return storage[call.byte_offset:call.byte_offset + call.byte_count]
}

// Scripted_Writer borrows all supplied slices. It performs no allocation.
// Writes beyond the script return full success, making short scripts useful
// for injecting one fault while allowing an operation to continue.
Scripted_Writer :: struct {
	steps: []Scripted_Write,
	calls: []Scripted_Writer_Call,
	bytes: []byte,

	call_count:         int,
	write_count:        int,
	dropped_call_count: int,
	byte_count:         int,
	dropped_byte_count: int,
}

scripted_writer_init :: proc(
	state: ^Scripted_Writer,
	steps: []Scripted_Write,
	call_storage: []Scripted_Writer_Call,
	byte_storage: []byte,
) {
	state^ = {}
	state.steps = steps
	state.calls = call_storage
	state.bytes = byte_storage
}

@(require_results)
scripted_writer :: proc(state: ^Scripted_Writer) -> io.Writer {
	return {procedure = scripted_writer_proc, data = state}
}

scripted_writer_proc :: proc(
	stream_data: rawptr,
	mode: io.Stream_Mode,
	p: []byte,
	offset: i64,
	whence: io.Seek_From,
) -> (n: i64, err: io.Error) {
	_, _ = offset, whence
	state := (^Scripted_Writer)(stream_data)

	call_index := state.call_count
	state.call_count += 1
	if call_index < len(state.calls) {
		state.calls[call_index] = {
			ordinal = state.call_count,
			mode = mode,
		}
	} else {
		state.dropped_call_count += 1
		call_index = -1
	}

	#partial switch mode {
	case .Write:
		write_index := state.write_count
		state.write_count += 1
		step := Scripted_Write{count_kind = .Full}
		if write_index < len(state.steps) {
			step = state.steps[write_index]
		}

		switch step.count_kind {
		case .Exact:
			n = step.count
		case .Full:
			n = i64(len(p))
		case .Negative:
			n = -1
		case .Past_End:
			n = i64(len(p)) + 1
		}
		err = step.error

		byte_offset := state.byte_count
		available := len(state.bytes) - state.byte_count
		to_copy := min(len(p), max(available, 0))
		if to_copy > 0 {
			copy(state.bytes[state.byte_count:state.byte_count + to_copy], p[:to_copy])
			state.byte_count += to_copy
		}
		state.dropped_byte_count += len(p) - to_copy

		if call_index >= 0 {
			state.calls[call_index].write_ordinal = state.write_count
			state.calls[call_index].requested_count = len(p)
			state.calls[call_index].returned_count = n
			state.calls[call_index].error = err
			state.calls[call_index].byte_offset = byte_offset
			state.calls[call_index].byte_count = to_copy
		}
		return
	case .Query:
		return transmute(i64)(io.Stream_Mode_Set{.Write, .Query}), nil
	case:
		err = .Unsupported
		if call_index >= 0 {
			state.calls[call_index].error = err
		}
		return 0, err
	}
}

package test_support

import "core:io"
import "core:testing"

@(test)
test_scripted_writer_returns_all_count_error_classes_and_records_once :: proc(t: ^testing.T) {
	steps := []Scripted_Write{
		{count_kind = .Exact, count = 0},
		{count_kind = .Exact, count = 0, error = .Unknown},
		{count_kind = .Exact, count = 1},
		{count_kind = .Exact, count = 1, error = .Unknown},
		{count_kind = .Exact, count = 2},
		{count_kind = .Exact, count = 2, error = .Unknown},
		{count_kind = .Full},
		{count_kind = .Full, error = .Unknown},
		{count_kind = .Negative},
		{count_kind = .Negative, error = .Unknown},
		{count_kind = .Past_End},
		{count_kind = .Past_End, error = .Unknown},
	}
	expected_counts := [12]int{0, 0, 1, 1, 2, 2, 3, 3, -1, -1, 4, 4}
	expected_errors := [12]io.Error{
		.None, .Unknown,
		.None, .Unknown,
		.None, .Unknown,
		.None, .Unknown,
		.None, .Unknown,
		.None, .Unknown,
	}
	call_storage: [16]Scripted_Writer_Call
	byte_storage: [48]byte
	state: Scripted_Writer
	scripted_writer_init(&state, steps, call_storage[:], byte_storage[:])
	writer := scripted_writer(&state)

	for _, index in steps {
		count, err := io.write_string(writer, "abc")
		testing.expect_value(t, count, expected_counts[index])
		testing.expect_value(t, err, expected_errors[index])
	}

	testing.expect_value(t, state.call_count, len(steps))
	testing.expect_value(t, state.write_count, len(steps))
	testing.expect_value(t, state.dropped_call_count, 0)
	testing.expect_value(t, state.dropped_byte_count, 0)
	testing.expect_value(t, state.byte_count, 3 * len(steps))
	for call, index in state.calls[:state.call_count] {
		testing.expect_value(t, call.ordinal, index + 1)
		testing.expect_value(t, call.requested_count, len(requested_bytes(call, state.bytes)))
		testing.expect_value(t, string(requested_bytes(call, state.bytes)), "abc")
	}
}

@(test)
test_scripted_writer_defaults_to_full_success_after_script :: proc(t: ^testing.T) {
	calls: [3]Scripted_Writer_Call
	bytes: [4]byte
	state: Scripted_Writer
	scripted_writer_init(&state, nil, calls[:], bytes[:])

	writer := scripted_writer(&state)
	count, err := io.write_string(writer, "odin")
	testing.expect_value(t, count, 4)
	testing.expect_value(t, err, io.Error.None)
	modes := io.query(writer)
	testing.expect(t, .Write in modes)
	testing.expect_value(t, io.flush(writer), io.Error.Unsupported)

	testing.expect_value(t, state.call_count, 3)
	testing.expect_value(t, state.write_count, 1)
	testing.expect_value(t, state.calls[0].mode, io.Stream_Mode.Write)
	testing.expect_value(t, state.calls[1].mode, io.Stream_Mode.Query)
	testing.expect_value(t, state.calls[2].mode, io.Stream_Mode.Flush)
	testing.expect_value(t, string(requested_bytes(state.calls[0], state.bytes)), "odin")
}

package semantic_fuzz_test

import "core:fmt"
import "core:io"
import "core:mem"
import "core:testing"
import toml "../.."
import temporal "../../vendor/temporal"
import test_support "../support"

MALFORMED_OWNER_KIND_COUNT :: 7

fuzz_document_is_zero :: proc(doc: toml.Document) -> bool {
	return raw_data(doc.root) == nil && len(doc.root) == 0 && cap(doc.root) == 0 &&
	       doc.root.allocator.procedure == nil && doc.allocator.procedure == nil
}

run_strict_parse_target :: proc(t: ^testing.T, input: []byte) {
	live: [512]test_support.Live_Allocation
	observed: test_support.Observed_Allocator
	test_support.observed_allocator_init(
		&observed,
		context.allocator,
		nil,
		live[:],
	)
	selected := test_support.observed_allocator(&observed)
	doc, err := toml.parse_bytes(input, allocator = selected)
	if err != nil {
		testing.expect(t, fuzz_document_is_zero(doc))
		testing.expect_value(t, observed.live_count, 0)
		testing.expect_value(t, observed.foreign_release_count, 0)
		return
	}
	toml.destroy_document(&doc)
	testing.expect(t, fuzz_document_is_zero(doc))
	testing.expect_value(t, observed.live_count, 0)
	testing.expect_value(t, observed.foreign_release_count, 0)
}

run_parse_unparse_composition_target :: proc(t: ^testing.T, input: []byte) {
	live: [1024]test_support.Live_Allocation
	observed: test_support.Observed_Allocator
	test_support.observed_allocator_init(
		&observed,
		context.allocator,
		nil,
		live[:],
	)
	selected := test_support.observed_allocator(&observed)

	doc, parse_error := toml.parse_bytes(input, allocator = selected)
	if parse_error != nil {
		testing.expect(t, fuzz_document_is_zero(doc))
		testing.expect_value(t, observed.live_count, 0)
		return
	}

	canonical, unparse_error := toml.unparse(&doc, allocator = selected)
	testing.expect(t, unparse_error == nil)
	if unparse_error != nil {
		toml.destroy_document(&doc)
		testing.expect_value(t, observed.live_count, 0)
		return
	}

	reparsed, reparse_error := toml.parse_string(canonical, allocator = selected)
	testing.expect(t, reparse_error == nil)
	if reparse_error == nil {
		testing.expect(t, test_support.semantic_table_equal(doc.root, reparsed.root))
		reencoded, reencode_error := toml.unparse(&reparsed, allocator = selected)
		testing.expect(t, reencode_error == nil)
		if reencode_error == nil {
			testing.expect_value(t, reencoded, canonical)
			delete(reencoded, selected)
		}
		toml.destroy_document(&reparsed)
	}

	composed, empty_error := toml.parse_string("", allocator = selected)
	testing.expect(t, empty_error == nil)
	if empty_error == nil {
		composed_ok := true
		for &entry in doc.root {
			if set_error := toml.set(&composed.root, entry.key, &entry.value); set_error != nil {
				composed_ok = false
				break
			}
		}
		testing.expect(t, composed_ok)
		if composed_ok {
			testing.expect(t, test_support.semantic_table_equal(doc.root, composed.root))
			composed_text, composed_error := toml.unparse(&composed, allocator = selected)
			testing.expect(t, composed_error == nil)
			if composed_error == nil {
				testing.expect_value(t, composed_text, canonical)
				delete(composed_text, selected)
			}
		}
		toml.destroy_document(&composed)
	}

	delete(canonical, selected)
	toml.destroy_document(&doc)
	testing.expect_value(t, observed.live_count, 0)
	testing.expect_value(t, observed.foreign_release_count, 0)
	testing.expect_value(t, observed.live_overflow_count, 0)
}

mutate_valid_utf8_seed :: proc(
	random: ^test_support.Replay_Random,
	seed: string,
	storage: []byte,
) -> []byte {
	replacements := [?]string{"a", "0", " ", "\n", "=", "[", "]", "α", "🪶"}
	operation := test_support.replay_int_max(random, 4)
	position := 0
	if len(seed) > 0 {
		position = test_support.replay_int_max(random, len(seed)+1)
		for position < len(seed) && seed[position]&0xc0 == 0x80 {
			position += 1
		}
	}
	replacement := replacements[test_support.replay_int_max(random, len(replacements))]

	prefix_end := position
	suffix_start := position
	switch operation {
	case 0:
		// Insert one complete scalar or ASCII syntax byte at a scalar boundary.
	case 1:
		// Replace one complete scalar, never one byte of a multi-byte scalar.
		if suffix_start < len(seed) {
			suffix_start += 1
			for suffix_start < len(seed) && seed[suffix_start]&0xc0 == 0x80 {
				suffix_start += 1
			}
		}
	case 2:
		// Delete one complete scalar.
		replacement = ""
		if suffix_start < len(seed) {
			suffix_start += 1
			for suffix_start < len(seed) && seed[suffix_start]&0xc0 == 0x80 {
				suffix_start += 1
			}
		}
	case 3:
		// Truncate only at a scalar boundary.
		replacement = ""
		suffix_start = len(seed)
	}

	count := copy(storage, transmute([]byte)seed[:prefix_end])
	count += copy(storage[count:], transmute([]byte)replacement)
	count += copy(storage[count:], transmute([]byte)seed[suffix_start:])
	return storage[:count]
}

run_valid_utf8_parser_mutation_target :: proc(t: ^testing.T, input: []byte) {
	run_strict_parse_target(t, input)
	run_parse_unparse_composition_target(t, input)
}

fuzz_input_integer :: proc(input: []byte) -> toml.Integer {
	value: u64 = 0xcbf29ce484222325
	for item in input {
		value = (value ~ u64(item))*0x100000001b3
	}
	return toml.Integer(cast(i64)value)
}

run_semantic_lifecycle_target :: proc(t: ^testing.T, input: []byte) {
	live: [256]test_support.Live_Allocation
	observed: test_support.Observed_Allocator
	test_support.observed_allocator_init(
		&observed,
		context.allocator,
		nil,
		live[:],
	)
	selected := test_support.observed_allocator(&observed)
	doc, parse_error := toml.parse_string(
		`keep = [{ nested = [1, 2, 3] }]` + "\n" + `remove = "owner"` + "\n",
		allocator = selected,
	)
	assert(parse_error == nil)

	clone, clone_error := toml.clone_document(&doc, selected)
	testing.expect(t, clone_error == nil)
	if clone_error == nil {
		borrowed, found := toml.get(&clone.root, "keep")
		testing.expect(t, found)
		if found {
			standalone, value_error := toml.clone_value(borrowed, selected)
			testing.expect(t, value_error == nil)
			if value_error == nil {
				toml.destroy_value(&standalone, selected)
				toml.destroy_value(&standalone, selected)
			}
		}

		replacement := toml.Value(fuzz_input_integer(input))
		testing.expect(t, toml.set(&clone.root, "keep", &replacement) == nil)
		inserted := toml.Value(toml.Boolean(len(input)&1 == 0))
		testing.expect(t, toml.set(&clone.root, "inserted", &inserted) == nil)
		testing.expect(t, toml.remove(&clone.root, "remove"))
		_, removed := toml.get(&clone.root, "remove")
		testing.expect(t, !removed)
		toml.destroy_document(&clone)
		toml.destroy_document(&clone)
	}

	toml.destroy_document(&doc)
	toml.destroy_document(&doc)
	testing.expect_value(t, observed.live_count, 0)
	testing.expect_value(t, observed.foreign_release_count, 0)
	testing.expect_value(t, observed.live_overflow_count, 0)
}

fuzz_owned_string :: proc(text: string, allocator: mem.Allocator) -> string {
	if len(text) == 0 {
		return ""
	}
	bytes, err := make([]byte, len(text), allocator)
	assert(err == nil)
	copy(bytes, transmute([]byte)text)
	return string(bytes)
}

make_malformed_owner :: proc(
	selector: int,
	allocator, other_allocator: mem.Allocator,
) -> toml.Document {
	root, root_error := make(toml.Table, 1, allocator)
	assert(root_error == nil)
	root[0].key = fuzz_owned_string("root", allocator)

	switch selector {
	case 0:
		uninitialized: toml.Array
		root[0].value = toml.Value(uninitialized)
	case 1:
		invalid, invalid_error := make([]byte, 1, allocator)
		assert(invalid_error == nil)
		invalid[0] = 0xff
		root[0].value = toml.Value(toml.String(string(invalid)))
	case 2:
		table, table_error := make(toml.Table, 2, allocator)
		assert(table_error == nil)
		table[0] = {
			key = fuzz_owned_string("duplicate", allocator),
			value = toml.Value(toml.Integer(1)),
		}
		table[1] = {
			key = fuzz_owned_string("duplicate", allocator),
			value = toml.Value(toml.Integer(2)),
		}
		root[0].value = toml.Value(table)
	case 3:
		cycle, cycle_error := make(toml.Array, 1, allocator)
		assert(cycle_error == nil)
		cycle[0] = toml.Value(cycle)
		root[0].value = toml.Value(cycle)
	case 4:
		shared := fuzz_owned_string("shared", allocator)
		aliases, aliases_error := make(toml.Array, 2, allocator)
		assert(aliases_error == nil)
		aliases[0] = toml.Value(toml.String(shared))
		aliases[1] = toml.Value(toml.String(shared))
		root[0].value = toml.Value(aliases)
	case 5:
		mismatched, mismatch_error := make(toml.Array, other_allocator)
		assert(mismatch_error == nil)
		root[0].value = toml.Value(mismatched)
	case 6:
		root[0].value = toml.Value(temporal.Local_Date{2024, 2, 30})
	case:
		unreachable()
	}
	return {root = root, allocator = allocator}
}

run_malformed_owner_validation_target :: proc(t: ^testing.T, selector_byte: byte) {
	storage: [32*1024]byte
	other_storage: [4096]byte
	arena, other_arena: mem.Arena
	mem.arena_init(&arena, storage[:])
	mem.arena_init(&other_arena, other_storage[:])
	allocator := mem.arena_allocator(&arena)
	other_allocator := mem.arena_allocator(&other_arena)
	selector := int(selector_byte)%MALFORMED_OWNER_KIND_COUNT
	doc := make_malformed_owner(selector, allocator, other_allocator)

	clone, clone_error := toml.clone_document(&doc)
	testing.expect(t, clone_error != nil)
	if clone_error == nil {
		toml.destroy_document(&clone)
	} else {
		testing.expect(t, fuzz_document_is_zero(clone))
	}
	output, unparse_error := toml.unparse(&doc)
	testing.expect(t, unparse_error != nil)
	if unparse_error == nil {
		delete(output)
	} else {
		testing.expect(t, raw_data(output) == nil)
	}

	target, target_error := toml.parse_string("stable = 1\n")
	assert(target_error == nil)
	malformed_value := toml.Value(doc.root)
	set_error := toml.set(&target.root, "malformed", &malformed_value)
	testing.expect(t, set_error != nil)
	_, inserted := toml.get(&target.root, "malformed")
	testing.expect(t, !inserted)
	toml.destroy_document(&target)

	// The malformed owner deliberately violates destroy_document/destroy_value
	// preconditions. Reclaim both complete external lifetimes; never salvage-walk it.
	mem.arena_free_all(&other_arena)
	mem.arena_free_all(&arena)
}

fuzz_byte_at :: proc(input: []byte, index: int) -> byte {
	if len(input) == 0 {
		return byte(index*37+11)
	}
	return input[index%len(input)]
}

accepted_prefix_from_fuzz_calls :: proc(
	state: ^test_support.Scripted_Writer,
	output: []byte,
) -> int {
	count := 0
	for call in state.calls[:min(state.call_count, len(state.calls))] {
		if call.mode != .Write || call.returned_count < 0 ||
		   call.returned_count > i64(call.requested_count) {
			continue
		}
		accepted := int(call.returned_count)
		requested := test_support.requested_bytes(call, state.bytes)
		assert(count+accepted <= len(output))
		copy(output[count:count+accepted], requested[:accepted])
		count += accepted
	}
	return count
}

run_writer_validation_target :: proc(t: ^testing.T, input: []byte) {
	value := fuzz_input_integer(input)
	source := fmt.aprintf(
		`first = "canonical"` + "\n" + `values = [1, 2, 3]` + "\n" +
			`nested.enabled = true` + "\n" + `nested.value = %d` + "\n",
		value,
	)
	defer delete(source)
	doc, parse_error := toml.parse_string(source)
	assert(parse_error == nil, source)
	defer toml.destroy_document(&doc)
	canonical, canonical_error := toml.unparse(&doc)
	assert(canonical_error == nil)
	defer delete(canonical)
	options: toml.Marshal_Options

	baseline_calls: [256]test_support.Scripted_Writer_Call
	baseline_bytes: [4096]byte
	baseline: test_support.Scripted_Writer
	test_support.scripted_writer_init(
		&baseline,
		nil,
		baseline_calls[:],
		baseline_bytes[:],
	)
	baseline_error := toml.unparse_to_writer(
		test_support.scripted_writer(&baseline),
		&doc,
		&options,
	)
	assert(baseline_error == nil)
	assert(baseline.write_count > 0 && baseline.write_count < len(baseline.calls))
	assert(string(baseline_bytes[:baseline.byte_count]) == canonical)

	ordinal := 1+int(fuzz_byte_at(input, 0))%baseline.write_count
	request_count := baseline.calls[ordinal-1].requested_count
	assert(request_count > 0)
	mode := int(fuzz_byte_at(input, 1))%6
	explicit_errors := [?]io.Error{
		.EOF, .Unexpected_EOF, .Short_Write, .Invalid_Write, .Short_Buffer,
		.No_Progress, .Invalid_Whence, .Invalid_Offset, .Invalid_Unread,
		.Negative_Read, .Negative_Write, .Negative_Count, .Buffer_Full,
		.Unknown, .No_Size, .Permission_Denied, .Closed, .Unsupported,
	}
	explicit_error := explicit_errors[int(fuzz_byte_at(input, 2))%len(explicit_errors)]
	step: test_support.Scripted_Write
	expected_error: io.Error
	switch mode {
	case 0:
		step = {
			count_kind = .Exact,
			count = i64(int(fuzz_byte_at(input, 3))%request_count),
		}
		expected_error = .Short_Write
	case 1:
		step = {count_kind = .Negative}
		expected_error = .Invalid_Write
	case 2:
		step = {count_kind = .Past_End}
		expected_error = .Invalid_Write
	case 3:
		step = {
			count_kind = .Exact,
			count = i64(int(fuzz_byte_at(input, 3))%(request_count+1)),
			error = explicit_error,
		}
		expected_error = explicit_error
	case 4:
		step = {count_kind = .Negative, error = explicit_error}
		expected_error = explicit_error
	case 5:
		step = {count_kind = .Past_End, error = explicit_error}
		expected_error = explicit_error
	}

	steps: [256]test_support.Scripted_Write
	for index in 0..<ordinal-1 {
		steps[index] = {count_kind = .Full}
	}
	steps[ordinal-1] = step
	calls: [256]test_support.Scripted_Writer_Call
	requested: [4096]byte
	state: test_support.Scripted_Writer
	test_support.scripted_writer_init(&state, steps[:ordinal], calls[:], requested[:])
	live: [128]test_support.Live_Allocation
	observed: test_support.Observed_Allocator
	test_support.observed_allocator_init(
		&observed,
		context.allocator,
		nil,
		live[:],
	)
	err := toml.unparse_to_writer(
		test_support.scripted_writer(&state),
		&doc,
		&options,
		test_support.observed_allocator(&observed),
	)
	actual_error, ok := err.(io.Error)
	testing.expect(t, ok)
	if ok {
		testing.expect_value(t, actual_error, expected_error)
	}
	testing.expect_value(t, state.write_count, ordinal)
	testing.expect_value(t, state.call_count, ordinal)
	testing.expect_value(t, observed.live_count, 0)
	testing.expect_value(t, observed.foreign_release_count, 0)

	accepted: [4096]byte
	accepted_count := accepted_prefix_from_fuzz_calls(&state, accepted[:])
	testing.expect(t, accepted_count <= len(canonical))
	if accepted_count <= len(canonical) {
		testing.expect_value(
			t,
			string(accepted[:accepted_count]),
			canonical[:accepted_count],
		)
	}
}

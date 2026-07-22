package semantic_fuzz_test

import "core:io"
import "core:mem"
import "core:os"
import "core:unicode/utf8"
import toml "../.."
import test_support "../support"

coverage_strict_parse_target :: proc(input: []byte) {
	doc, err := toml.parse_bytes(input)
	if err == nil {
		toml.destroy_document(&doc)
	} else {
		assert(fuzz_document_is_zero(doc))
	}
}

coverage_parse_unparse_target :: proc(input: []byte) {
	doc, parse_error := toml.parse_bytes(input)
	if parse_error != nil {
		assert(fuzz_document_is_zero(doc))
		return
	}
	defer toml.destroy_document(&doc)
	canonical, unparse_error := toml.unparse(&doc)
	assert(unparse_error == nil)
	defer delete(canonical)
	reparsed, reparse_error := toml.parse_string(canonical)
	assert(reparse_error == nil)
	defer toml.destroy_document(&reparsed)
	assert(test_support.semantic_table_equal(doc.root, reparsed.root))
	reencoded, reencode_error := toml.unparse(&reparsed)
	assert(reencode_error == nil)
	defer delete(reencoded)
	assert(reencoded == canonical)
}

coverage_semantic_lifecycle_target :: proc(input: []byte) {
	doc, parse_error := toml.parse_string("keep = [1, 2, 3]\nremove = true\n")
	assert(parse_error == nil)
	clone, clone_error := toml.clone_document(&doc)
	assert(clone_error == nil)
	borrowed, found := toml.get(&clone.root, "keep")
	assert(found)
	owned, value_error := toml.clone_value(borrowed)
	assert(value_error == nil)
	toml.destroy_value(&owned, context.allocator)
	replacement := toml.Value(fuzz_input_integer(input))
	assert(toml.set(&clone.root, "keep", &replacement) == nil)
	assert(toml.remove(&clone.root, "remove"))
	toml.destroy_document(&clone)
	toml.destroy_document(&clone)
	toml.destroy_document(&doc)
	toml.destroy_document(&doc)

	storage: [32*1024]byte
	other_storage: [4096]byte
	arena, other_arena: mem.Arena
	mem.arena_init(&arena, storage[:])
	mem.arena_init(&other_arena, other_storage[:])
	allocator := mem.arena_allocator(&arena)
	other_allocator := mem.arena_allocator(&other_arena)
	selector := int(fuzz_byte_at(input, 0))%MALFORMED_OWNER_KIND_COUNT
	malformed := make_malformed_owner(selector, allocator, other_allocator)
	failed_clone, failed_clone_error := toml.clone_document(&malformed)
	assert(failed_clone_error != nil)
	assert(fuzz_document_is_zero(failed_clone))
	output, output_error := toml.unparse(&malformed)
	assert(output_error != nil)
	assert(raw_data(output) == nil)
	stable, stable_error := toml.parse_string("stable = 1\n")
	assert(stable_error == nil)
	malformed_value := toml.Value(malformed.root)
	assert(toml.set(&stable.root, "malformed", &malformed_value) != nil)
	toml.destroy_document(&stable)
	// Deliberately malformed owners are reclaimed only as external lifetimes.
	mem.arena_free_all(&other_arena)
	mem.arena_free_all(&arena)
}

coverage_writer_validation_target :: proc(input: []byte) {
	doc, parse_error := toml.parse_string(
		"first = \"canonical\"\nvalues = [1, 2, 3]\nnested.enabled = true\n",
	)
	assert(parse_error == nil)
	defer toml.destroy_document(&doc)
	canonical, canonical_error := toml.unparse(&doc)
	assert(canonical_error == nil)
	defer delete(canonical)
	options: toml.Marshal_Options

	baseline_calls: [256]test_support.Scripted_Writer_Call
	baseline_bytes: [4096]byte
	baseline: test_support.Scripted_Writer
	test_support.scripted_writer_init(&baseline, nil, baseline_calls[:], baseline_bytes[:])
	assert(toml.unparse_to_writer(
		test_support.scripted_writer(&baseline),
		&doc,
		&options,
	) == nil)
	assert(string(baseline_bytes[:baseline.byte_count]) == canonical)
	ordinal := 1+int(fuzz_byte_at(input, 0))%baseline.write_count
	request_count := baseline.calls[ordinal-1].requested_count
	mode := int(fuzz_byte_at(input, 1))%3
	step: test_support.Scripted_Write
	expected: io.Error
	switch mode {
	case 0:
		step = {
			count_kind = .Exact,
			count = i64(int(fuzz_byte_at(input, 2))%request_count),
		}
		expected = .Short_Write
	case 1:
		step = {count_kind = .Negative}
		expected = .Invalid_Write
	case 2:
		step = {
			count_kind = .Past_End,
			error = .Permission_Denied,
		}
		expected = .Permission_Denied
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
	err := toml.unparse_to_writer(
		test_support.scripted_writer(&state),
		&doc,
		&options,
	)
	actual, ok := err.(io.Error)
	assert(ok && actual == expected)
	assert(state.write_count == ordinal && state.call_count == ordinal)
	accepted: [4096]byte
	accepted_count := accepted_prefix_from_fuzz_calls(&state, accepted[:])
	assert(accepted_count <= len(canonical))
	assert(string(accepted[:accepted_count]) == canonical[:accepted_count])
}

main :: proc() {
	if len(os.args) != 2 {
		_, _ = os.write_string(
			os.stderr,
			"usage: semantic-fuzz <strict-parse|valid-utf8|parse-unparse|semantic-lifecycle|writer-validation>\n",
		)
		os.exit(2)
	}
	input, read_error := os.read_entire_file(os.stdin, context.allocator)
	if read_error != nil {
		_, _ = os.write_string(os.stderr, "semantic-fuzz: could not read stdin\n")
		os.exit(2)
	}
	defer delete(input)

	switch os.args[1] {
	case "strict-parse":
		coverage_strict_parse_target(input)
	case "valid-utf8":
		if utf8.valid_string(string(input)) {
			coverage_parse_unparse_target(input)
		}
	case "parse-unparse":
		coverage_parse_unparse_target(input)
	case "semantic-lifecycle":
		coverage_semantic_lifecycle_target(input)
	case "writer-validation":
		coverage_writer_validation_target(input)
	case:
		_, _ = os.write_string(os.stderr, "semantic-fuzz: unknown target\n")
		os.exit(2)
	}
}

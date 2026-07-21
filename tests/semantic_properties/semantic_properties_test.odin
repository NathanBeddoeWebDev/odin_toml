package semantic_properties_test

import "core:fmt"
import "core:strings"
import "core:testing"
import toml "../.."
import test_support "../support"

write_generated_value :: proc(
	builder: ^strings.Builder,
	random: ^test_support.Replay_Random,
	depth: int,
) {
	choice_limit := 10 if depth < 2 else 8
	choice := test_support.replay_int_max(random, choice_limit)
	switch choice {
	case 0:
		fmt.sbprintf(builder, `"text-%d-α"`, test_support.replay_int_max(random, 10_000))
	case 1:
		value := test_support.replay_int_max(random, 2_000_001)-1_000_000
		fmt.sbprintf(builder, "%d", value)
	case 2:
		values := [?]string{"-0.0", "0.125", "-3.5", "1e+20", "inf", "-inf", "nan"}
		strings.write_string(builder, values[test_support.replay_int_max(random, len(values))])
	case 3:
		strings.write_string(
			builder,
			"true" if test_support.replay_int_max(random, 2) == 0 else "false",
		)
	case 4:
		strings.write_string(builder, "2024-02-29T15:16:17.123456789+05:30")
	case 5:
		strings.write_string(builder, "2024-02-29T15:16:17.123456789")
	case 6:
		strings.write_string(builder, "2024-02-29")
	case 7:
		strings.write_string(builder, "15:16:17.123456789")
	case 8:
		strings.write_byte(builder, '[')
		count := test_support.replay_int_max(random, 5)
		for index in 0..<count {
			if index > 0 {
				strings.write_string(builder, ", ")
			}
			write_generated_value(builder, random, depth+1)
		}
		strings.write_byte(builder, ']')
	case 9:
		strings.write_string(builder, "{ ")
		count := test_support.replay_int_max(random, 4)
		for index in 0..<count {
			if index > 0 {
				strings.write_string(builder, ", ")
			}
			fmt.sbprintf(builder, `"member-%d" = `, index)
			write_generated_value(builder, random, depth+1)
		}
		strings.write_string(builder, " }")
	}
}

write_generated_document :: proc(
	builder: ^strings.Builder,
	random: ^test_support.Replay_Random,
	case_index: int,
	ordered: ^[5]toml.Integer,
) {
	strings.write_string(builder, `"ordered" = [`)
	for index in 0..<len(ordered) {
		ordered[index] = toml.Integer(
			test_support.replay_int_max(random, 2_000_001)-1_000_000,
		)
		if index > 0 {
			strings.write_string(builder, ", ")
		}
		fmt.sbprintf(builder, "%d", ordered[index])
	}
	strings.write_string(builder, "]\n")

	entry_count := 1+test_support.replay_int_max(random, 6)
	for index in 0..<entry_count {
		fmt.sbprintf(builder, `"case-%d-entry-%d" = `, case_index, index)
		write_generated_value(builder, random, 0)
		strings.write_byte(builder, '\n')
	}
}

compose_document_through_public_set :: proc(
	source: ^toml.Document,
) -> (toml.Document, bool) {
	composed, parse_error := toml.parse_string("")
	if parse_error != nil {
		return {}, false
	}
	for &entry in source.root {
		if mutation_error := toml.set(
			&composed.root,
			entry.key,
			&entry.value,
		); mutation_error != nil {
			toml.destroy_document(&composed)
			return {}, false
		}
	}
	return composed, true
}

expect_ordered_array :: proc(
	t: ^testing.T,
	table: ^toml.Table,
	expected: [5]toml.Integer,
) {
	value, found := toml.get(table, "ordered")
	testing.expect(t, found)
	if !found {
		return
	}
	array, ok := value^.(toml.Array)
	testing.expect(t, ok)
	if !ok {
		return
	}
	testing.expect_value(t, len(array), len(expected))
	if len(array) != len(expected) {
		return
	}
	for &child, index in array {
		integer, integer_ok := child.(toml.Integer)
		testing.expect(t, integer_ok)
		if integer_ok {
			testing.expect_value(t, integer, expected[index])
		}
	}
}

@(test)
test_replayable_generated_semantic_trees_compose_through_public_workflows :: proc(t: ^testing.T) {
	random := test_support.replay_random_from_test(t, "semantic-properties")
	options: toml.Marshal_Options

	for case_index in 0..<128 {
		builder, builder_error := strings.builder_make()
		assert(builder_error == nil)
		ordered: [5]toml.Integer
		write_generated_document(&builder, &random, case_index, &ordered)

		generated_source, parse_error := toml.parse_string(strings.to_string(builder))
		strings.builder_destroy(&builder)
		testing.expect(t, parse_error == nil)
		if parse_error != nil {
			continue
		}
		doc, composed := compose_document_through_public_set(&generated_source)
		toml.destroy_document(&generated_source)
		testing.expect(t, composed)
		if !composed {
			continue
		}

		first, first_error := toml.unparse(&doc)
		testing.expect(t, first_error == nil)
		if first_error != nil {
			toml.destroy_document(&doc)
			continue
		}
		second, second_error := toml.unparse(&doc)
		testing.expect(t, second_error == nil)
		if second_error == nil {
			testing.expect_value(t, second, first)
			delete(second)
		}

		writer_builder, writer_builder_error := strings.builder_make()
		assert(writer_builder_error == nil)
		writer_error := toml.unparse_to_writer(
			strings.to_writer(&writer_builder),
			&doc,
			&options,
		)
		testing.expect(t, writer_error == nil)
		if writer_error == nil {
			testing.expect_value(t, strings.to_string(writer_builder), first)
		}
		strings.builder_destroy(&writer_builder)

		reparsed, reparse_error := toml.parse_string(first)
		testing.expect(t, reparse_error == nil)
		if reparse_error == nil {
			testing.expect(t, test_support.semantic_table_equal(doc.root, reparsed.root))
			expect_ordered_array(t, &reparsed.root, ordered)
			reencoded, reencode_error := toml.unparse(&reparsed)
			testing.expect(t, reencode_error == nil)
			if reencode_error == nil {
				testing.expect_value(t, reencoded, first)
				delete(reencoded)
			}
			toml.destroy_document(&reparsed)
		}

		cloned, clone_error := toml.clone_document(&doc)
		testing.expect(t, clone_error == nil)
		if clone_error == nil {
			testing.expect(t, test_support.semantic_table_equal(doc.root, cloned.root))
			replacement := toml.Value(toml.Integer(10_000_000+case_index))
			mutation_error := toml.set(&cloned.root, doc.root[0].key, &replacement)
			testing.expect(t, mutation_error == nil)
			clone_only := toml.Value(toml.String("independent"))
			mutation_error = toml.set(&cloned.root, "clone-only", &clone_only)
			testing.expect(t, mutation_error == nil)
			_, original_has_clone_only := toml.get(&doc.root, "clone-only")
			testing.expect(t, !original_has_clone_only)
			testing.expect_value(t, cloned.root[len(cloned.root)-1].key, "clone-only")

			original_after_mutation, original_error := toml.unparse(&doc)
			testing.expect(t, original_error == nil)
			if original_error == nil {
				testing.expect_value(t, original_after_mutation, first)
				delete(original_after_mutation)
			}
			clone_output, clone_output_error := toml.unparse(&cloned)
			testing.expect(t, clone_output_error == nil)
			if clone_output_error == nil {
				testing.expect(t, clone_output != first)
				delete(clone_output)
			}
			toml.destroy_document(&cloned)
		}

		expect_ordered_array(t, &doc.root, ordered)
		delete(first)
		toml.destroy_document(&doc)
	}
}

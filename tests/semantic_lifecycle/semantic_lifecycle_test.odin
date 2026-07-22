package semantic_lifecycle_test

import "base:runtime"
import "core:mem"
import "core:testing"
import toml "../.."
import temporal "../../vendor/temporal"
import test_support "../support"

allocator_equal :: proc(a, b: mem.Allocator) -> bool {
	return a.procedure == b.procedure && a.data == b.data
}

document_is_zero :: proc(doc: toml.Document) -> bool {
	return raw_data(doc.root) == nil && len(doc.root) == 0 && cap(doc.root) == 0 &&
	       doc.root.allocator.procedure == nil && doc.root.allocator.data == nil &&
	       doc.allocator.procedure == nil && doc.allocator.data == nil
}

owned_string :: proc(text: string, allocator: mem.Allocator) -> string {
	if len(text) == 0 {
		return ""
	}
	bytes, err := make([]byte, len(text), allocator)
	assert(err == nil)
	copy(bytes, transmute([]byte)text)
	return string(bytes)
}

make_lifecycle_document :: proc(allocator: mem.Allocator) -> toml.Document {
	root, root_error := make(toml.Table, 11, allocator)
	assert(root_error == nil)
	keys := [11]string{
		"string", "empty-string", "integer", "float", "boolean",
		"offset-date-time", "local-date-time", "local-date", "local-time",
		"array", "table",
	}
	for key, index in keys {
		root[index].key = owned_string(key, allocator)
	}

	root[0].value = toml.Value(toml.String(owned_string("source", allocator)))
	root[1].value = toml.Value(toml.String(""))
	root[2].value = toml.Value(toml.Integer(-17))
	root[3].value = toml.Value(toml.Float(3.5))
	root[4].value = toml.Value(toml.Boolean(true))
	root[5].value = toml.Value(temporal.Offset_Date_Time{
		local = {date = {2026, 7, 21}, time = {12, 34, 56, 789}},
		offset = {.Unknown, 0},
	})
	root[6].value = toml.Value(temporal.Local_Date_Time{
		date = {2024, 2, 29},
		time = {23, 59, 60, 999_999_999},
	})
	root[7].value = toml.Value(temporal.Local_Date{0, 1, 1})
	root[8].value = toml.Value(temporal.Local_Time{0, 0, 0, 0})

	array, array_error := make(toml.Array, 2, allocator)
	assert(array_error == nil)
	array[0] = toml.Value(toml.String(owned_string("array-string", allocator)))
	empty_table, empty_table_error := make(toml.Table, allocator)
	assert(empty_table_error == nil)
	array[1] = toml.Value(empty_table)
	root[9].value = toml.Value(array)

	table, table_error := make(toml.Table, 1, allocator)
	assert(table_error == nil)
	table[0].key = owned_string("empty-array", allocator)
	empty_array, empty_array_error := make(toml.Array, allocator)
	assert(empty_array_error == nil)
	table[0].value = toml.Value(empty_array)
	root[10].value = toml.Value(table)

	return {root = root, allocator = allocator}
}

@(test)
test_empty_trivia_documents_are_initialized_owners :: proc(t: ^testing.T) {
	inputs := [6]string{"", " \t\n", "# comment", "# first\r\n# second\r\n", " \t# comment\n", "# unicode: 🪶\n"}
	for input in inputs {
		doc, err := toml.parse_string(input)
		testing.expect(t, err == nil)
		testing.expect_value(t, len(doc.root), 0)
		testing.expect(t, doc.root.allocator.procedure != nil)
		testing.expect(t, allocator_equal(doc.root.allocator, doc.allocator))

		empty_clone, clone_error := toml.clone_document(&doc)
		testing.expect(t, clone_error == nil)
		testing.expect_value(t, len(empty_clone.root), 0)
		testing.expect(t, empty_clone.root.allocator.procedure != nil)
		toml.destroy_document(&empty_clone)

		bytes_doc, bytes_error := toml.parse_bytes(transmute([]byte)input)
		testing.expect(t, bytes_error == nil)
		testing.expect_value(t, len(bytes_doc.root), 0)
		testing.expect(t, bytes_doc.root.allocator.procedure != nil)
		toml.destroy_document(&bytes_doc)

		toml.destroy_document(&doc)
		testing.expect(t, document_is_zero(doc))
	}
}

@(test)
test_empty_parse_retains_explicit_allocator_without_ambient_fallback :: proc(t: ^testing.T) {
	backing := context.allocator
	events: [8]test_support.Allocator_Event
	live: [1]test_support.Live_Allocation
	observed: test_support.Observed_Allocator
	test_support.observed_allocator_init(&observed, backing, events[:], live[:])
	selected := test_support.observed_allocator(&observed)
	rejecting: test_support.Rejecting_Allocator
	context.allocator = test_support.rejecting_allocator(&rejecting)

	doc, err := toml.parse_string("# empty owner\n", allocator = selected)
	retained := allocator_equal(doc.allocator, selected) &&
	            allocator_equal(doc.root.allocator, selected)
	toml.destroy_document(&doc)
	ambient_calls := rejecting.call_count
	context.allocator = backing

	testing.expect(t, err == nil)
	testing.expect(t, retained)
	testing.expect(t, document_is_zero(doc))
	testing.expect_value(t, ambient_calls, 0)
	testing.expect_value(t, observed.allocation_request_count, 0)
}

@(test)
test_get_returns_an_allocation_free_borrowed_value :: proc(t: ^testing.T) {
	backing := context.allocator
	table, allocation_error := make(toml.Table, 2, backing)
	testing.expect(t, allocation_error == nil)
	defer delete(table)
	table[0] = {key = "a.b", value = toml.Value(toml.Integer(17))}
	table[1] = {key = "name", value = toml.Value(toml.String("value"))}

	rejecting: test_support.Rejecting_Allocator
	context.allocator = test_support.rejecting_allocator(&rejecting)
	defer context.allocator = backing

	borrowed, ok := toml.get(&table, "a.b")
	testing.expect(t, ok)
	testing.expect(t, borrowed == &table[0].value)
	integer, integer_ok := borrowed.(toml.Integer)
	testing.expect(t, integer_ok)
	testing.expect_value(t, integer, toml.Integer(17))

	missing, missing_ok := toml.get(&table, "a")
	testing.expect(t, !missing_ok)
	testing.expect_value(t, missing, (^toml.Value)(nil))
	testing.expect_value(t, rejecting.call_count, 0)
}

@(test)
test_document_and_standalone_value_clones_are_deep_ordered_and_independent :: proc(t: ^testing.T) {
	backing := context.allocator
	source := make_lifecycle_document(backing)

	events: [256]test_support.Allocator_Event
	live: [64]test_support.Live_Allocation
	observed: test_support.Observed_Allocator
	test_support.observed_allocator_init(&observed, backing, events[:], live[:])
	selected := test_support.observed_allocator(&observed)
	rejecting: test_support.Rejecting_Allocator
	context.allocator = test_support.rejecting_allocator(&rejecting)
	defer context.allocator = backing

	clone, clone_error := toml.clone_document(&source, selected)
	testing.expect(t, clone_error == nil)
	testing.expect(t, allocator_equal(clone.allocator, selected))
	testing.expect(t, allocator_equal(clone.root.allocator, selected))
	testing.expect_value(t, len(clone.root), len(source.root))
	testing.expect(t, raw_data(clone.root) != raw_data(source.root))
	for entry, index in clone.root {
		testing.expect_value(t, entry.key, source.root[index].key)
		if len(entry.key) > 0 {
			testing.expect(t, raw_data(entry.key) != raw_data(source.root[index].key))
		}
	}

	clone_string, clone_string_ok := clone.root[0].value.(toml.String)
	source_string, source_string_ok := source.root[0].value.(toml.String)
	testing.expect(t, clone_string_ok && source_string_ok)
	testing.expect_value(t, clone_string, source_string)
	testing.expect(t, raw_data(clone_string) != raw_data(source_string))
	clone_array, clone_array_ok := clone.root[9].value.(toml.Array)
	source_array, source_array_ok := source.root[9].value.(toml.Array)
	testing.expect(t, clone_array_ok && source_array_ok)
	testing.expect(t, raw_data(clone_array) != raw_data(source_array))
	cloned_empty_table, cloned_empty_table_ok := clone_array[1].(toml.Table)
	testing.expect(t, cloned_empty_table_ok)
	testing.expect(t, allocator_equal(cloned_empty_table.allocator, selected))
	clone_table, clone_table_ok := clone.root[10].value.(toml.Table)
	testing.expect(t, clone_table_ok)
	cloned_empty_array, cloned_empty_array_ok := clone_table[0].value.(toml.Array)
	testing.expect(t, cloned_empty_array_ok)
	testing.expect(t, allocator_equal(cloned_empty_array.allocator, selected))

	clone.root[2].value = toml.Value(toml.Integer(99))
	source_integer, source_integer_ok := source.root[2].value.(toml.Integer)
	testing.expect(t, source_integer_ok)
	testing.expect_value(t, source_integer, toml.Integer(-17))

	for &entry, index in source.root {
		value_clone, value_clone_error := toml.clone_value(&entry.value, selected)
		testing.expect(t, value_clone_error == nil)
		if index == 9 {
			cloned_array, cloned_array_ok := value_clone.(toml.Array)
			testing.expect(t, cloned_array_ok)
			testing.expect(t, allocator_equal(cloned_array.allocator, selected))
			testing.expect(t, raw_data(cloned_array) != raw_data(source_array))
			nested_empty, nested_empty_ok := cloned_array[1].(toml.Table)
			testing.expect(t, nested_empty_ok)
			testing.expect(t, allocator_equal(nested_empty.allocator, selected))
		}
		toml.destroy_value(&value_clone, selected)
		query_count := observed.kind_counts[.Query_Features]
		toml.destroy_value(&value_clone, selected)
		testing.expect_value(t, observed.kind_counts[.Query_Features], query_count)
		zero_string, zero_string_ok := value_clone.(toml.String)
		testing.expect(t, zero_string_ok)
		testing.expect_value(t, zero_string, "")
	}

	toml.destroy_document(&clone)
	toml.destroy_document(&clone)
	testing.expect(t, document_is_zero(clone))
	testing.expect_value(t, observed.live_count, 0)
	testing.expect_value(t, observed.foreign_release_count, 0)
	testing.expect_value(t, rejecting.call_count, 0)

	toml.destroy_document(&source)
	toml.destroy_document(&source)
	testing.expect(t, document_is_zero(source))
}

@(test)
test_nil_allocator_owner_calls_fail_before_allocation :: proc(t: ^testing.T) {
	nil_allocator: mem.Allocator
	doc, parse_error := toml.parse_string("", allocator = nil_allocator)
	testing.expect(t, document_is_zero(doc))
	parse_configuration, parse_configuration_ok := parse_error.(toml.Parse_Configuration_Error)
	testing.expect(t, parse_configuration_ok)
	testing.expect_value(t, parse_configuration, toml.Parse_Configuration_Error.Invalid_Allocator)

	source, source_error := toml.parse_string("")
	testing.expect(t, source_error == nil)
	defer toml.destroy_document(&source)
	clone, clone_error := toml.clone_document(&source, nil_allocator)
	testing.expect(t, document_is_zero(clone))
	clone_configuration, clone_configuration_ok := clone_error.(toml.Clone_Configuration_Error)
	testing.expect(t, clone_configuration_ok)
	testing.expect_value(t, clone_configuration, toml.Clone_Configuration_Error.Invalid_Allocator)

	value := toml.Value(toml.String(""))
	_, value_error := toml.clone_value(&value, nil_allocator)
	value_configuration, value_configuration_ok := value_error.(toml.Clone_Configuration_Error)
	testing.expect(t, value_configuration_ok)
	testing.expect_value(t, value_configuration, toml.Clone_Configuration_Error.Invalid_Allocator)
}

@(test)
test_clone_failure_is_transactional_at_every_allocation_ordinal :: proc(t: ^testing.T) {
	backing := context.allocator
	source := make_lifecycle_document(backing)
	defer toml.destroy_document(&source)
	source_root := raw_data(source.root)
	source_text, source_text_ok := source.root[0].value.(toml.String)
	testing.expect(t, source_text_ok)
	source_text_data := raw_data(source_text)

	baseline_events: [256]test_support.Allocator_Event
	baseline_live: [64]test_support.Live_Allocation
	baseline_state: test_support.Observed_Allocator
	test_support.observed_allocator_init(
		&baseline_state,
		backing,
		baseline_events[:],
		baseline_live[:],
	)
	baseline_allocator := test_support.observed_allocator(&baseline_state)
	baseline_clone, baseline_error := toml.clone_document(&source, baseline_allocator)
	testing.expect(t, baseline_error == nil)
	allocation_count := baseline_state.allocation_request_count
	toml.destroy_document(&baseline_clone)
	testing.expect(t, allocation_count > 0)
	testing.expect_value(t, baseline_state.live_count, 0)

	for fail_at in 1 ..= allocation_count {
		events: [256]test_support.Allocator_Event
		live: [64]test_support.Live_Allocation
		state: test_support.Observed_Allocator
		test_support.observed_allocator_init(&state, backing, events[:], live[:])
		state.fail_at_allocation = fail_at
		selected := test_support.observed_allocator(&state)

		rejecting: test_support.Rejecting_Allocator
		context.allocator = test_support.rejecting_allocator(&rejecting)
		clone, clone_error := toml.clone_document(&source, selected)
		context.allocator = backing

		testing.expect(t, document_is_zero(clone))
		allocator_error, allocator_error_ok := clone_error.(runtime.Allocator_Error)
		testing.expect(t, allocator_error_ok)
		testing.expect_value(t, allocator_error, runtime.Allocator_Error.Out_Of_Memory)
		testing.expect_value(t, state.live_count, 0)
		testing.expect_value(t, state.foreign_release_count, 0)
		testing.expect_value(t, rejecting.call_count, 0)
		testing.expect(t, raw_data(source.root) == source_root)
		unchanged_text, unchanged_text_ok := source.root[0].value.(toml.String)
		testing.expect(t, unchanged_text_ok)
		testing.expect(t, raw_data(unchanged_text) == source_text_data)
		testing.expect_value(t, unchanged_text, "source")
	}

	beyond_events: [256]test_support.Allocator_Event
	beyond_live: [64]test_support.Live_Allocation
	beyond_state: test_support.Observed_Allocator
	test_support.observed_allocator_init(
		&beyond_state,
		backing,
		beyond_events[:],
		beyond_live[:],
	)
	beyond_state.fail_at_allocation = allocation_count + 1
	beyond_allocator := test_support.observed_allocator(&beyond_state)
	rejecting: test_support.Rejecting_Allocator
	context.allocator = test_support.rejecting_allocator(&rejecting)
	beyond_clone, beyond_error := toml.clone_document(&source, beyond_allocator)
	context.allocator = backing
	testing.expect(t, beyond_error == nil)
	testing.expect_value(t, len(beyond_clone.root), len(source.root))
	testing.expect_value(t, rejecting.call_count, 0)
	toml.destroy_document(&beyond_clone)
	testing.expect_value(t, beyond_state.live_count, 0)

	baseline_value_events: [64]test_support.Allocator_Event
	baseline_value_live: [16]test_support.Live_Allocation
	baseline_value_state: test_support.Observed_Allocator
	test_support.observed_allocator_init(
		&baseline_value_state,
		backing,
		baseline_value_events[:],
		baseline_value_live[:],
	)
	baseline_value_allocator := test_support.observed_allocator(&baseline_value_state)
	baseline_value, baseline_value_error := toml.clone_value(
		&source.root[9].value,
		baseline_value_allocator,
	)
	testing.expect(t, baseline_value_error == nil)
	value_allocation_count := baseline_value_state.allocation_request_count
	toml.destroy_value(&baseline_value, baseline_value_allocator)
	testing.expect(t, value_allocation_count > 0)
	testing.expect_value(t, baseline_value_state.live_count, 0)

	for fail_at in 1 ..= value_allocation_count {
		events: [64]test_support.Allocator_Event
		live: [16]test_support.Live_Allocation
		state: test_support.Observed_Allocator
		test_support.observed_allocator_init(&state, backing, events[:], live[:])
		state.fail_at_allocation = fail_at
		selected := test_support.observed_allocator(&state)
		failed_value, failed_value_error := toml.clone_value(&source.root[9].value, selected)
		allocator_error, allocator_error_ok := failed_value_error.(runtime.Allocator_Error)
		testing.expect(t, allocator_error_ok)
		testing.expect_value(t, allocator_error, runtime.Allocator_Error.Out_Of_Memory)
		zero_string, zero_string_ok := failed_value.(toml.String)
		testing.expect(t, zero_string_ok)
		testing.expect_value(t, zero_string, "")
		testing.expect_value(t, state.live_count, 0)
		testing.expect_value(t, state.foreign_release_count, 0)
	}

	beyond_value_events: [64]test_support.Allocator_Event
	beyond_value_live: [16]test_support.Live_Allocation
	beyond_value_state: test_support.Observed_Allocator
	test_support.observed_allocator_init(
		&beyond_value_state,
		backing,
		beyond_value_events[:],
		beyond_value_live[:],
	)
	beyond_value_state.fail_at_allocation = value_allocation_count + 1
	beyond_value_allocator := test_support.observed_allocator(&beyond_value_state)
	beyond_value, beyond_value_error := toml.clone_value(
		&source.root[9].value,
		beyond_value_allocator,
	)
	testing.expect(t, beyond_value_error == nil)
	toml.destroy_value(&beyond_value, beyond_value_allocator)
	testing.expect_value(t, beyond_value_state.live_count, 0)
}

@(test)
test_external_lifetime_clones_are_logically_destroyed_without_free_all :: proc(t: ^testing.T) {
	backing := context.allocator
	source := make_lifecycle_document(backing)
	defer toml.destroy_document(&source)

	buffer: [8192]byte
	arena: mem.Arena
	mem.arena_init(&arena, buffer[:])

	reported: test_support.External_Lifetime_Allocator
	test_support.external_lifetime_allocator_init(&reported, mem.arena_allocator(&arena), true)
	reported_allocator := test_support.external_lifetime_allocator(&reported)
	reported_clone, reported_error := toml.clone_document(&source, reported_allocator)
	testing.expect(t, reported_error == nil)
	testing.expect(t, arena.offset > 0)
	toml.destroy_document(&reported_clone)
	testing.expect(t, document_is_zero(reported_clone))
	testing.expect_value(t, reported.release_attempt_count, 0)
	testing.expect_value(t, reported.free_all_count, 0)
	mem.arena_free_all(&arena)

	unreported: test_support.External_Lifetime_Allocator
	test_support.external_lifetime_allocator_init(&unreported, mem.arena_allocator(&arena), false)
	unreported_allocator := test_support.external_lifetime_allocator(&unreported)
	standalone, standalone_error := toml.clone_value(&source.root[9].value, unreported_allocator)
	testing.expect(t, standalone_error == nil)
	testing.expect(t, arena.offset > 0)
	release_attempts_before_destroy := unreported.release_attempt_count
	toml.destroy_value(&standalone, unreported_allocator)
	query_count := unreported.query_features_count
	toml.destroy_value(&standalone, unreported_allocator)
	zero_string, zero_string_ok := standalone.(toml.String)
	testing.expect(t, zero_string_ok)
	testing.expect_value(t, zero_string, "")
	testing.expect_value(t, unreported.query_features_count, query_count)
	testing.expect_value(
		t,
		unreported.release_attempt_count,
		release_attempts_before_destroy + 1,
	)
	testing.expect_value(t, unreported.free_all_count, 0)
	mem.arena_free_all(&arena)
}

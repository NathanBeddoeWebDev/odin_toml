package semantic_mutation_test

import "base:runtime"
import "core:mem"
import "core:reflect"
import "core:testing"
import toml "../.."
import temporal "../../temporal"
import test_support "../support"

owned_string :: proc(text: string, allocator: mem.Allocator) -> string {
	if len(text) == 0 {
		return ""
	}
	bytes, err := make([]byte, len(text), allocator)
	assert(err == nil)
	copy(bytes, transmute([]byte)text)
	return string(bytes)
}

make_empty_document :: proc(allocator: mem.Allocator) -> toml.Document {
	doc, err := toml.parse_string("", allocator = allocator)
	assert(err == nil)
	return doc
}

mutation_diagnostic :: proc(
	t: ^testing.T,
	err: toml.Mutation_Error,
	kind: toml.Mutation_Data_Error_Kind,
) -> toml.Mutation_Diagnostic {
	diagnostic, ok := err.(toml.Mutation_Diagnostic)
	testing.expect(t, ok)
	if !ok {
		return {}
	}
	actual, detail_ok := diagnostic.detail.(toml.Mutation_Data_Error_Kind)
	testing.expect(t, detail_ok)
	if detail_ok {
		testing.expect_value(t, actual, kind)
	}
	if kind != .Invalid_Temporal {
		testing.expect_value(t, diagnostic.temporal_error, temporal.Error.None)
	}
	expect_encode_path_metadata(t, diagnostic.path)
	return diagnostic
}

expect_encode_path_metadata :: proc(t: ^testing.T, path: toml.Encode_Diagnostic_Path) {
	if path.total_segment_count <= 32 {
		testing.expect_value(t, path.segment_count, u8(path.total_segment_count))
		testing.expect_value(t, path.prefix_count, u8(path.total_segment_count))
		testing.expect_value(t, path.omitted_segment_count, u16(0))
		testing.expect(t, !path.truncated)
	} else {
		testing.expect_value(t, path.segment_count, u8(32))
		testing.expect_value(t, path.prefix_count, u8(8))
		testing.expect_value(t, path.omitted_segment_count, path.total_segment_count-32)
		testing.expect(t, path.truncated)
	}
}

mutation_limit_diagnostic :: proc(
	t: ^testing.T,
	err: toml.Mutation_Error,
	kind: toml.Mutation_Limit_Error,
) -> toml.Mutation_Diagnostic {
	diagnostic, ok := err.(toml.Mutation_Diagnostic)
	testing.expect(t, ok)
	if !ok {
		return {}
	}
	actual, detail_ok := diagnostic.detail.(toml.Mutation_Limit_Error)
	testing.expect(t, detail_ok)
	if detail_ok {
		testing.expect_value(t, actual, kind)
	}
	testing.expect_value(t, diagnostic.temporal_error, temporal.Error.None)
	expect_encode_path_metadata(t, diagnostic.path)
	return diagnostic
}

clone_data_diagnostic :: proc(
	t: ^testing.T,
	err: toml.Clone_Error,
	kind: toml.Clone_Data_Error_Kind,
) -> toml.Clone_Diagnostic {
	diagnostic, ok := err.(toml.Clone_Diagnostic)
	testing.expect(t, ok)
	if !ok {
		return {}
	}
	actual, detail_ok := diagnostic.detail.(toml.Clone_Data_Error_Kind)
	testing.expect(t, detail_ok)
	if detail_ok {
		testing.expect_value(t, actual, kind)
	}
	if kind != .Invalid_Temporal {
		testing.expect_value(t, diagnostic.temporal_error, temporal.Error.None)
	}
	expect_encode_path_metadata(t, diagnostic.path)
	return diagnostic
}

expect_path_key :: proc(
	t: ^testing.T,
	path: toml.Encode_Diagnostic_Path,
	index: int,
	expected: string,
) {
	actual, ok := path.segments[index].(string)
	testing.expect(t, ok)
	if ok {
		testing.expect_value(t, actual, expected)
	}
}

make_nested_arrays :: proc(depth: int, allocator: mem.Allocator) -> toml.Value {
	result := toml.Value(toml.Integer(1))
	for _ in 0 ..< depth {
		array, err := make(toml.Array, 1, allocator)
		assert(err == nil)
		array[0] = result
		result = toml.Value(array)
	}
	return result
}

raw_table_state :: proc(table: toml.Table) -> runtime.Raw_Dynamic_Array {
	return transmute(runtime.Raw_Dynamic_Array)table
}

@(test)
test_set_replaces_in_place_appends_and_deep_clones_caller_values :: proc(t: ^testing.T) {
	allocator := context.allocator
	doc := make_empty_document(allocator)
	defer toml.destroy_document(&doc)

	first := toml.Value(toml.String(owned_string("caller", allocator)))
	defer toml.destroy_value(&first, allocator)
	second := toml.Value(toml.Integer(2))
	replacement := toml.Value(toml.Integer(3))

	testing.expect(t, toml.set(&doc.root, "first", &first) == nil)
	caller_text, caller_text_ok := first.(toml.String)
	stored_text, stored_text_ok := doc.root[0].value.(toml.String)
	testing.expect(t, caller_text_ok && stored_text_ok)
	if caller_text_ok && stored_text_ok {
		testing.expect_value(t, stored_text, caller_text)
		testing.expect(t, raw_data(stored_text) != raw_data(caller_text))
	}

	testing.expect(t, toml.set(&doc.root, "second", &second) == nil)
	testing.expect(t, toml.set(&doc.root, "first", &replacement) == nil)
	testing.expect_value(t, len(doc.root), 2)
	testing.expect_value(t, doc.root[0].key, "first")
	testing.expect_value(t, doc.root[1].key, "second")
	stored, stored_ok := doc.root[0].value.(toml.Integer)
	testing.expect(t, stored_ok)
	testing.expect_value(t, stored, toml.Integer(3))

	caller_text, caller_text_ok = first.(toml.String)
	testing.expect(t, caller_text_ok)
	if caller_text_ok {
		testing.expect_value(t, caller_text, "caller")
	}
}

@(test)
test_remove_stably_compacts_and_reinsert_appends :: proc(t: ^testing.T) {
	doc := make_empty_document(context.allocator)
	defer toml.destroy_document(&doc)
	values := [3]toml.Value{
		toml.Value(toml.Integer(1)),
		toml.Value(toml.Integer(2)),
		toml.Value(toml.Integer(3)),
	}
	keys := [3]string{"a", "b", "c"}
	for key, index in keys {
		testing.expect(t, toml.set(&doc.root, key, &values[index]) == nil)
	}

	testing.expect(t, toml.remove(&doc.root, "b"))
	testing.expect_value(t, len(doc.root), 2)
	testing.expect_value(t, doc.root[0].key, "a")
	testing.expect_value(t, doc.root[1].key, "c")
	testing.expect(t, !toml.remove(&doc.root, "missing"))
	testing.expect(t, toml.set(&doc.root, "b", &values[1]) == nil)
	testing.expect_value(t, len(doc.root), 3)
	testing.expect_value(t, doc.root[0].key, "a")
	testing.expect_value(t, doc.root[1].key, "c")
	testing.expect_value(t, doc.root[2].key, "b")
}

@(test)
test_set_reports_exact_text_temporal_container_and_union_errors :: proc(t: ^testing.T) {
	doc := make_empty_document(context.allocator)
	defer toml.destroy_document(&doc)
	valid := toml.Value(toml.Integer(1))

	invalid_key_bytes := [1]byte{0xff}
	invalid_key := string(invalid_key_bytes[:])
	key_diagnostic := mutation_diagnostic(
		t,
		toml.set(&doc.root, invalid_key, &valid),
		.Invalid_Key_Text,
	)
	testing.expect_value(t, key_diagnostic.path.total_segment_count, u16(1))
	expect_path_key(t, key_diagnostic.path, 0, invalid_key)

	invalid_value_bytes := [1]byte{0xff}
	invalid_text := toml.Value(toml.String(string(invalid_value_bytes[:])))
	text_diagnostic := mutation_diagnostic(
		t,
		toml.set(&doc.root, "text", &invalid_text),
		.Invalid_Value_Text,
	)
	testing.expect_value(t, text_diagnostic.path.total_segment_count, u16(1))
	expect_path_key(t, text_diagnostic.path, 0, "text")

	invalid_temporal := toml.Value(temporal.Local_Date{year = 2024, month = 2, day = 30})
	temporal_diagnostic := mutation_diagnostic(
		t,
		toml.set(&doc.root, "when", &invalid_temporal),
		.Invalid_Temporal,
	)
	testing.expect_value(t, temporal_diagnostic.temporal_error, temporal.Error.Invalid_Day)
	expect_path_key(t, temporal_diagnostic.path, 0, "when")

	uninitialized_array: toml.Array
	invalid_container := toml.Value(uninitialized_array)
	container_diagnostic := mutation_diagnostic(
		t,
		toml.set(&doc.root, "items", &invalid_container),
		.Allocator_Mismatch,
	)
	expect_path_key(t, container_diagnostic.path, 0, "items")

	malformed_raw := runtime.Raw_Dynamic_Array{
		len = 1,
		cap = 1,
		allocator = context.allocator,
	}
	malformed_array := transmute(toml.Array)malformed_raw
	malformed_container := toml.Value(malformed_array)
	malformed_diagnostic := mutation_diagnostic(
		t,
		toml.set(&doc.root, "malformed", &malformed_container),
		.Invalid_Value_State,
	)
	expect_path_key(t, malformed_diagnostic.path, 0, "malformed")

	invalid_union := toml.Value(toml.Integer(1))
	reflect.set_union_variant_raw_tag(invalid_union, 255)
	union_diagnostic := mutation_diagnostic(
		t,
		toml.set(&doc.root, "invalid", &invalid_union),
		.Invalid_Value_State,
	)
	expect_path_key(t, union_diagnostic.path, 0, "invalid")
	testing.expect_value(t, len(doc.root), 0)
}

@(test)
test_set_rejects_duplicate_cycle_alias_and_allocator_mismatch_graphs :: proc(t: ^testing.T) {
	backing := context.allocator
	doc := make_empty_document(backing)
	defer toml.destroy_document(&doc)

	duplicate_buffer: [4096]byte
	duplicate_arena: mem.Arena
	mem.arena_init(&duplicate_arena, duplicate_buffer[:])
	duplicate_allocator := mem.arena_allocator(&duplicate_arena)
	duplicate_table, duplicate_error := make(toml.Table, 2, duplicate_allocator)
	assert(duplicate_error == nil)
	duplicate_table[0] = {
		key = owned_string("same", duplicate_allocator),
		value = toml.Value(toml.Integer(1)),
	}
	duplicate_table[1] = {
		key = owned_string("same", duplicate_allocator),
		value = toml.Value(toml.Integer(2)),
	}
	duplicate := toml.Value(duplicate_table)
	duplicate_diagnostic := mutation_diagnostic(
		t,
		toml.set(&doc.root, "value", &duplicate),
		.Duplicate_Key,
	)
	testing.expect_value(t, duplicate_diagnostic.path.total_segment_count, u16(2))
	expect_path_key(t, duplicate_diagnostic.path, 0, "value")
	expect_path_key(t, duplicate_diagnostic.path, 1, "same")
	mem.arena_free_all(&duplicate_arena)

	cycle_buffer: [4096]byte
	cycle_arena: mem.Arena
	mem.arena_init(&cycle_arena, cycle_buffer[:])
	cycle_allocator := mem.arena_allocator(&cycle_arena)
	cycle_array, cycle_error := make(toml.Array, 1, cycle_allocator)
	assert(cycle_error == nil)
	cycle_array[0] = toml.Value(cycle_array)
	cycle := toml.Value(cycle_array)
	cycle_diagnostic := mutation_diagnostic(
		t,
		toml.set(&doc.root, "value", &cycle),
		.Cycle,
	)
	testing.expect_value(t, cycle_diagnostic.path.total_segment_count, u16(2))
	mem.arena_free_all(&cycle_arena)

	overlap_buffer: [4096]byte
	overlap_arena: mem.Arena
	mem.arena_init(&overlap_arena, overlap_buffer[:])
	overlap_allocator := mem.arena_allocator(&overlap_arena)
	overlap_parent, overlap_error := make(toml.Array, 1, overlap_allocator)
	assert(overlap_error == nil)
	overlap_raw := runtime.Raw_Dynamic_Array{
		data = rawptr(uintptr(raw_data(overlap_parent)) + 1),
		len = 0,
		cap = 1,
		allocator = overlap_allocator,
	}
	overlap_child := transmute(toml.Array)overlap_raw
	overlap_parent[0] = toml.Value(overlap_child)
	overlap_value := toml.Value(overlap_parent)
	overlap_diagnostic := mutation_diagnostic(
		t,
		toml.set(&doc.root, "value", &overlap_value),
		.Ownership_Alias,
	)
	testing.expect_value(t, overlap_diagnostic.path.total_segment_count, u16(2))
	mem.arena_free_all(&overlap_arena)

	alias_buffer: [4096]byte
	alias_arena: mem.Arena
	mem.arena_init(&alias_arena, alias_buffer[:])
	alias_allocator := mem.arena_allocator(&alias_arena)
	alias_text := owned_string("aliased", alias_allocator)
	alias_array, alias_error := make(toml.Array, 2, alias_allocator)
	assert(alias_error == nil)
	alias_array[0] = toml.Value(toml.String(alias_text))
	alias_array[1] = toml.Value(toml.String(alias_text))
	alias := toml.Value(alias_array)
	alias_diagnostic := mutation_diagnostic(
		t,
		toml.set(&doc.root, "value", &alias),
		.Ownership_Alias,
	)
	testing.expect_value(t, alias_diagnostic.path.total_segment_count, u16(2))
	mem.arena_free_all(&alias_arena)

	outer_buffer: [4096]byte
	inner_buffer: [4096]byte
	outer_arena, inner_arena: mem.Arena
	mem.arena_init(&outer_arena, outer_buffer[:])
	mem.arena_init(&inner_arena, inner_buffer[:])
	outer_allocator := mem.arena_allocator(&outer_arena)
	inner_allocator := mem.arena_allocator(&inner_arena)
	inner, inner_error := make(toml.Array, inner_allocator)
	assert(inner_error == nil)
	outer, outer_error := make(toml.Array, 1, outer_allocator)
	assert(outer_error == nil)
	outer[0] = toml.Value(inner)
	mixed := toml.Value(outer)
	mismatch_diagnostic := mutation_diagnostic(
		t,
		toml.set(&doc.root, "value", &mixed),
		.Allocator_Mismatch,
	)
	testing.expect_value(t, mismatch_diagnostic.path.total_segment_count, u16(2))
	mem.arena_free_all(&inner_arena)
	mem.arena_free_all(&outer_arena)

	testing.expect_value(t, len(doc.root), 0)
}

@(test)
test_set_validates_existing_target_before_destructive_mutation :: proc(t: ^testing.T) {
	buffer: [8192]byte
	arena: mem.Arena
	mem.arena_init(&arena, buffer[:])
	allocator := mem.arena_allocator(&arena)
	table, table_error := make(toml.Table, 2, allocator)
	assert(table_error == nil)
	table[0] = {
		key = owned_string("duplicate", allocator),
		value = toml.Value(toml.Integer(1)),
	}
	table[1] = {
		key = owned_string("duplicate", allocator),
		value = toml.Value(toml.Integer(2)),
	}
	before := raw_table_state(table)
	replacement := toml.Value(toml.Integer(3))
	diagnostic := mutation_diagnostic(
		t,
		toml.set(&table, "duplicate", &replacement),
		.Duplicate_Key,
	)
	testing.expect_value(t, diagnostic.path.total_segment_count, u16(1))
	after := raw_table_state(table)
	testing.expect(t, after.data == before.data)
	testing.expect_value(t, after.len, before.len)
	testing.expect_value(t, after.cap, before.cap)
	mem.arena_free_all(&arena)

	zero_table: toml.Table
	mutation_diagnostic(
		t,
		toml.set(&zero_table, "key", &replacement),
		.Allocator_Mismatch,
	)
	mutation_diagnostic(
		t,
		toml.set(nil, "key", &replacement),
		.Invalid_Table,
	)
}

@(test)
test_local_depth_256_succeeds_257_fails_and_root_clone_rechecks_depth :: proc(t: ^testing.T) {
	source_buffer: [65536]byte
	source_arena: mem.Arena
	mem.arena_init(&source_arena, source_buffer[:])
	source_allocator := mem.arena_allocator(&source_arena)

	doc := make_empty_document(context.allocator)
	defer toml.destroy_document(&doc)
	at_limit := make_nested_arrays(255, source_allocator)
	testing.expect(t, toml.set(&doc.root, "limit", &at_limit) == nil)
	before := raw_table_state(doc.root)
	beyond_limit := make_nested_arrays(256, source_allocator)
	limit_diagnostic := mutation_limit_diagnostic(
		t,
		toml.set(&doc.root, "too-deep", &beyond_limit),
		.Maximum_Depth_Exceeded,
	)
	testing.expect_value(t, limit_diagnostic.path.total_segment_count, u16(257))
	testing.expect(t, limit_diagnostic.path.truncated)
	testing.expect_value(t, limit_diagnostic.path.segment_count, u8(32))
	testing.expect_value(t, limit_diagnostic.path.prefix_count, u8(8))
	testing.expect_value(t, limit_diagnostic.path.omitted_segment_count, u16(225))
	after := raw_table_state(doc.root)
	testing.expect(t, after.data == before.data)
	testing.expect_value(t, after.len, before.len)
	testing.expect_value(t, after.cap, before.cap)

	nested_doc := make_empty_document(context.allocator)
	defer toml.destroy_document(&nested_doc)
	empty_table, empty_error := make(toml.Table, context.allocator)
	assert(empty_error == nil)
	empty_value := toml.Value(empty_table)
	testing.expect(t, toml.set(&nested_doc.root, "outer", &empty_value) == nil)
	toml.destroy_value(&empty_value, context.allocator)
	nested_value, found := toml.get(&nested_doc.root, "outer")
	assert(found)
	nested_table, table_ok := nested_value.(toml.Table)
	assert(table_ok)
	testing.expect(t, toml.set(&nested_table, "local", &at_limit) == nil)
	nested_value^ = toml.Value(nested_table)
	clone, clone_error := toml.clone_document(&nested_doc)
	clone_limit, clone_limit_ok := clone_error.(toml.Clone_Diagnostic)
	testing.expect(t, clone_limit_ok)
	if clone_limit_ok {
		limit, detail_ok := clone_limit.detail.(toml.Clone_Limit_Error)
		testing.expect(t, detail_ok)
		if detail_ok {
			testing.expect_value(t, limit, toml.Clone_Limit_Error.Maximum_Depth_Exceeded)
		}
		testing.expect_value(t, clone_limit.path.total_segment_count, u16(257))
	}
	testing.expect_value(t, len(clone.root), 0)

	mem.arena_free_all(&source_arena)
}

@(test)
test_clone_boundaries_reject_malformed_ownership_graphs_with_zero_results :: proc(t: ^testing.T) {
	cycle_buffer: [4096]byte
	cycle_arena: mem.Arena
	mem.arena_init(&cycle_arena, cycle_buffer[:])
	cycle_allocator := mem.arena_allocator(&cycle_arena)
	cycle_array, cycle_error := make(toml.Array, 1, cycle_allocator)
	assert(cycle_error == nil)
	cycle_array[0] = toml.Value(cycle_array)
	cycle_value := toml.Value(cycle_array)
	cycle_clone, cycle_clone_error := toml.clone_value(&cycle_value)
	clone_data_diagnostic(t, cycle_clone_error, .Cycle)
	cycle_zero, cycle_zero_ok := cycle_clone.(toml.String)
	testing.expect(t, cycle_zero_ok)
	if cycle_zero_ok {
		testing.expect_value(t, cycle_zero, "")
	}
	mem.arena_free_all(&cycle_arena)

	alias_buffer: [4096]byte
	alias_arena: mem.Arena
	mem.arena_init(&alias_arena, alias_buffer[:])
	alias_allocator := mem.arena_allocator(&alias_arena)
	alias_text := owned_string("same", alias_allocator)
	alias_table, alias_error := make(toml.Table, 1, alias_allocator)
	assert(alias_error == nil)
	alias_table[0] = {
		key = alias_text,
		value = toml.Value(toml.String(alias_text)),
	}
	alias_doc := toml.Document{root = alias_table, allocator = alias_allocator}
	alias_clone, alias_clone_error := toml.clone_document(&alias_doc)
	clone_data_diagnostic(t, alias_clone_error, .Ownership_Alias)
	testing.expect_value(t, len(alias_clone.root), 0)
	mem.arena_free_all(&alias_arena)

	text_buffer: [4096]byte
	text_arena: mem.Arena
	mem.arena_init(&text_arena, text_buffer[:])
	text_allocator := mem.arena_allocator(&text_arena)
	invalid_bytes, invalid_error := make([]byte, 1, text_allocator)
	assert(invalid_error == nil)
	invalid_bytes[0] = 0xff
	text_table, table_error := make(toml.Table, 1, text_allocator)
	assert(table_error == nil)
	text_table[0] = {
		key = owned_string("text", text_allocator),
		value = toml.Value(toml.String(string(invalid_bytes))),
	}
	text_doc := toml.Document{root = text_table, allocator = text_allocator}
	text_clone, text_clone_error := toml.clone_document(&text_doc)
	clone_data_diagnostic(t, text_clone_error, .Invalid_Text)
	testing.expect_value(t, len(text_clone.root), 0)
	mem.arena_free_all(&text_arena)

	malformed_raw := runtime.Raw_Dynamic_Array{
		len = 1,
		cap = 1,
		allocator = context.allocator,
	}
	malformed_array := transmute(toml.Array)malformed_raw
	malformed_value := toml.Value(malformed_array)
	malformed_clone, malformed_clone_error := toml.clone_value(&malformed_value)
	clone_data_diagnostic(t, malformed_clone_error, .Invalid_Container)
	malformed_zero, malformed_zero_ok := malformed_clone.(toml.String)
	testing.expect(t, malformed_zero_ok)
	if malformed_zero_ok {
		testing.expect_value(t, malformed_zero, "")
	}

	zero_array: toml.Array
	zero_value := toml.Value(zero_array)
	zero_clone, zero_clone_error := toml.clone_value(&zero_value)
	clone_data_diagnostic(t, zero_clone_error, .Invalid_Container)
	zero_text, zero_text_ok := zero_clone.(toml.String)
	testing.expect(t, zero_text_ok)
	if zero_text_ok {
		testing.expect_value(t, zero_text, "")
	}

	root_buffer: [128]byte
	document_buffer: [128]byte
	root_arena, document_arena: mem.Arena
	mem.arena_init(&root_arena, root_buffer[:])
	mem.arena_init(&document_arena, document_buffer[:])
	root_allocator := mem.arena_allocator(&root_arena)
	document_allocator := mem.arena_allocator(&document_arena)
	mismatched_root, root_error := make(toml.Table, root_allocator)
	assert(root_error == nil)
	mismatched_doc := toml.Document{
		root = mismatched_root,
		allocator = document_allocator,
	}
	mismatched_clone, mismatched_error := toml.clone_document(&mismatched_doc)
	clone_data_diagnostic(t, mismatched_error, .Allocator_Mismatch)
	testing.expect_value(t, len(mismatched_clone.root), 0)
	mem.arena_free_all(&document_arena)
	mem.arena_free_all(&root_arena)
}

@(test)
test_set_reports_size_overflow_before_touching_malformed_storage :: proc(t: ^testing.T) {
	raw := runtime.Raw_Dynamic_Array{
		data = rawptr(uintptr(1)),
		len = 0,
		cap = max(int),
		allocator = context.allocator,
	}
	table := transmute(toml.Table)raw
	value := toml.Value(toml.Integer(1))
	diagnostic := mutation_limit_diagnostic(
		t,
		toml.set(&table, "key", &value),
		.Size_Overflow,
	)
	testing.expect_value(t, diagnostic.path.total_segment_count, u16(0))
	after := raw_table_state(table)
	testing.expect(t, after.data == raw.data)
	testing.expect_value(t, after.len, raw.len)
	testing.expect_value(t, after.cap, raw.cap)

	malformed_doc := toml.Document{root = table, allocator = context.allocator}
	clone, clone_error := toml.clone_document(&malformed_doc)
	clone_diagnostic, clone_diagnostic_ok := clone_error.(toml.Clone_Diagnostic)
	testing.expect(t, clone_diagnostic_ok)
	if clone_diagnostic_ok {
		limit, limit_ok := clone_diagnostic.detail.(toml.Clone_Limit_Error)
		testing.expect(t, limit_ok)
		if limit_ok {
			testing.expect_value(t, limit, toml.Clone_Limit_Error.Size_Overflow)
		}
	}
	testing.expect_value(t, len(clone.root), 0)
}

@(test)
test_remove_destroys_through_table_owner_without_ambient_allocation :: proc(t: ^testing.T) {
	backing := context.allocator
	events: [128]test_support.Allocator_Event
	live: [32]test_support.Live_Allocation
	state: test_support.Observed_Allocator
	test_support.observed_allocator_init(&state, backing, events[:], live[:])
	selected := test_support.observed_allocator(&state)
	doc := make_empty_document(selected)
	value := toml.Value(toml.String("owned text"))
	assert(toml.set(&doc.root, "owned key", &value) == nil)
	before_live := state.live_count
	testing.expect(t, before_live >= 3)

	rejecting: test_support.Rejecting_Allocator
	context.allocator = test_support.rejecting_allocator(&rejecting)
	removed := toml.remove(&doc.root, "owned key")
	context.allocator = backing
	testing.expect(t, removed)
	testing.expect_value(t, len(doc.root), 0)
	testing.expect(t, state.live_count < before_live)
	testing.expect_value(t, state.foreign_release_count, 0)
	testing.expect_value(t, rejecting.call_count, 0)

	toml.destroy_document(&doc)
	testing.expect_value(t, state.live_count, 0)
}

@(test)
test_set_insertion_allocation_failures_are_physically_transactional :: proc(t: ^testing.T) {
	backing := context.allocator
	source := make_nested_arrays(2, backing)
	defer toml.destroy_value(&source, backing)

	baseline_events: [256]test_support.Allocator_Event
	baseline_live: [64]test_support.Live_Allocation
	baseline: test_support.Observed_Allocator
	test_support.observed_allocator_init(&baseline, backing, baseline_events[:], baseline_live[:])
	baseline_allocator := test_support.observed_allocator(&baseline)
	baseline_doc := make_empty_document(baseline_allocator)
	baseline_error := toml.set(&baseline_doc.root, "inserted", &source)
	testing.expect(t, baseline_error == nil)
	allocation_count := baseline.allocation_request_count
	testing.expect(t, allocation_count > 0)
	toml.destroy_document(&baseline_doc)
	testing.expect_value(t, baseline.live_count, 0)

	for fail_at in 1 ..= allocation_count {
		events: [256]test_support.Allocator_Event
		live: [64]test_support.Live_Allocation
		state: test_support.Observed_Allocator
		test_support.observed_allocator_init(&state, backing, events[:], live[:])
		selected := test_support.observed_allocator(&state)
		doc := make_empty_document(selected)
		before := raw_table_state(doc.root)
		state.fail_at_allocation = fail_at
		rejecting: test_support.Rejecting_Allocator
		context.allocator = test_support.rejecting_allocator(&rejecting)
		err := toml.set(&doc.root, "inserted", &source)
		context.allocator = backing
		allocator_error, ok := err.(runtime.Allocator_Error)
		testing.expect(t, ok)
		if ok {
			testing.expect_value(t, allocator_error, runtime.Allocator_Error.Out_Of_Memory)
		}
		after := raw_table_state(doc.root)
		testing.expect(t, after.data == before.data)
		testing.expect_value(t, after.len, before.len)
		testing.expect_value(t, after.cap, before.cap)
		testing.expect_value(t, state.live_count, 0)
		testing.expect_value(t, state.foreign_release_count, 0)
		testing.expect_value(t, rejecting.call_count, 0)
		toml.destroy_document(&doc)
	}

	events: [256]test_support.Allocator_Event
	live: [64]test_support.Live_Allocation
	state: test_support.Observed_Allocator
	test_support.observed_allocator_init(&state, backing, events[:], live[:])
	selected := test_support.observed_allocator(&state)
	doc := make_empty_document(selected)
	state.fail_at_allocation = allocation_count + 1
	rejecting: test_support.Rejecting_Allocator
	context.allocator = test_support.rejecting_allocator(&rejecting)
	beyond_error := toml.set(&doc.root, "inserted", &source)
	context.allocator = backing
	testing.expect(t, beyond_error == nil)
	testing.expect_value(t, len(doc.root), 1)
	testing.expect_value(t, rejecting.call_count, 0)
	toml.destroy_document(&doc)
	testing.expect_value(t, state.live_count, 0)
}

@(test)
test_set_replacement_allocation_failures_preserve_entry_and_owner :: proc(t: ^testing.T) {
	backing := context.allocator
	source := make_nested_arrays(2, backing)
	defer toml.destroy_value(&source, backing)

	baseline_events: [256]test_support.Allocator_Event
	baseline_live: [64]test_support.Live_Allocation
	baseline: test_support.Observed_Allocator
	test_support.observed_allocator_init(&baseline, backing, baseline_events[:], baseline_live[:])
	baseline_allocator := test_support.observed_allocator(&baseline)
	baseline_doc := make_empty_document(baseline_allocator)
	initial := toml.Value(toml.String(""))
	assert(toml.set(&baseline_doc.root, "entry", &initial) == nil)
	start_ordinal := baseline.allocation_request_count
	assert(toml.set(&baseline_doc.root, "entry", &source) == nil)
	allocation_count := baseline.allocation_request_count - start_ordinal
	testing.expect(t, allocation_count > 0)
	toml.destroy_document(&baseline_doc)
	testing.expect_value(t, baseline.live_count, 0)

	for fail_at in 1 ..= allocation_count {
		events: [256]test_support.Allocator_Event
		live: [64]test_support.Live_Allocation
		state: test_support.Observed_Allocator
		test_support.observed_allocator_init(&state, backing, events[:], live[:])
		selected := test_support.observed_allocator(&state)
		doc := make_empty_document(selected)
		assert(toml.set(&doc.root, "entry", &initial) == nil)
		before := raw_table_state(doc.root)
		before_key := raw_data(doc.root[0].key)
		before_live := state.live_count
		state.fail_at_allocation = state.allocation_request_count + fail_at
		rejecting: test_support.Rejecting_Allocator
		context.allocator = test_support.rejecting_allocator(&rejecting)
		err := toml.set(&doc.root, "entry", &source)
		context.allocator = backing
		allocator_error, ok := err.(runtime.Allocator_Error)
		testing.expect(t, ok)
		if ok {
			testing.expect_value(t, allocator_error, runtime.Allocator_Error.Out_Of_Memory)
		}
		after := raw_table_state(doc.root)
		testing.expect(t, after.data == before.data)
		testing.expect_value(t, after.len, before.len)
		testing.expect_value(t, after.cap, before.cap)
		testing.expect(t, raw_data(doc.root[0].key) == before_key)
		stored, stored_ok := doc.root[0].value.(toml.String)
		testing.expect(t, stored_ok)
		if stored_ok {
			testing.expect_value(t, stored, "")
		}
		testing.expect_value(t, state.live_count, before_live)
		testing.expect_value(t, state.foreign_release_count, 0)
		testing.expect_value(t, rejecting.call_count, 0)
		toml.destroy_document(&doc)
		testing.expect_value(t, state.live_count, 0)
	}

	events: [256]test_support.Allocator_Event
	live: [64]test_support.Live_Allocation
	state: test_support.Observed_Allocator
	test_support.observed_allocator_init(&state, backing, events[:], live[:])
	selected := test_support.observed_allocator(&state)
	doc := make_empty_document(selected)
	assert(toml.set(&doc.root, "entry", &initial) == nil)
	state.fail_at_allocation = state.allocation_request_count + allocation_count + 1
	rejecting: test_support.Rejecting_Allocator
	context.allocator = test_support.rejecting_allocator(&rejecting)
	beyond_error := toml.set(&doc.root, "entry", &source)
	context.allocator = backing
	testing.expect(t, beyond_error == nil)
	testing.expect_value(t, len(doc.root), 1)
	testing.expect_value(t, rejecting.call_count, 0)
	toml.destroy_document(&doc)
	testing.expect_value(t, state.live_count, 0)
}

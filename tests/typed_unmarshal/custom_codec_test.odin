package typed_unmarshal_test

import "base:runtime"
import "core:mem"
import "core:strings"
import "core:testing"
import "core:thread"
import toml "../.."
import temporal "../../temporal"
import test_support "../support"

Codec_Named_Integer :: distinct i32

Codec_Exact_Root :: struct {
	value: Codec_Named_Integer,
}

Codec_Invocation_State :: struct {
	call_count:         int,
	expected_allocator: mem.Allocator,
	expected_loc:       runtime.Source_Code_Location,
	contract_matched:   bool,
}

codec_allocator_equal :: proc(a, b: mem.Allocator) -> bool {
	return a.procedure == b.procedure && a.data == b.data
}

codec_location_equal :: proc(a, b: runtime.Source_Code_Location) -> bool {
	return a.file_path == b.file_path && a.line == b.line &&
	       a.column == b.column && a.procedure == b.procedure
}

unmarshal_named_integer :: proc(
	source: ^toml.Value,
	destination: any,
	user_data: rawptr,
	allocator: mem.Allocator,
	loc: runtime.Source_Code_Location,
) -> toml.Codec_Callback_Error {
	state := (^Codec_Invocation_State)(user_data)
	state.call_count += 1
	value, source_ok := source^.(toml.Integer)
	state.contract_matched = source != nil && source_ok && value == 41 &&
	                         destination.id == typeid_of(Codec_Named_Integer) &&
	                         (^Codec_Named_Integer)(destination.data)^ == 0 &&
	                         codec_allocator_equal(allocator, state.expected_allocator) &&
	                         codec_location_equal(loc, state.expected_loc)
	(^Codec_Named_Integer)(destination.data)^ = 42
	return nil
}

@(test)
unmarshal_codec_exact_lookup_precedes_named_generic_binding :: proc(t: ^testing.T) {
	registry, registry_error := toml.init_codec_registry()
	assert(registry_error == nil)
	defer toml.destroy_codec_registry(&registry)

	selected := context.allocator
	expected_loc := runtime.Source_Code_Location{
		file_path = "unmarshal-codec-contract.odin",
		line = 123,
		column = 7,
		procedure = "unmarshal_codec_contract",
	}
	state := Codec_Invocation_State{
		expected_allocator = selected,
		expected_loc = expected_loc,
	}
	assert(toml.register_unmarshaler(
		&registry,
		typeid_of(Codec_Named_Integer),
		{procedure = unmarshal_named_integer, user_data = &state},
	) == nil)

	destination: Codec_Exact_Root
	err := toml.unmarshal_string(
		"value = 41\n",
		&destination,
		{codecs = &registry},
		selected,
		expected_loc,
	)
	testing.expect(t, err == nil)
	testing.expect_value(t, state.call_count, 1)
	testing.expect(t, state.contract_matched)
	testing.expect_value(t, destination.value, Codec_Named_Integer(42))

	nonzero := Codec_Exact_Root{value = 7}
	nonzero_error := toml.unmarshal_string(
		"value = 41\n", &nonzero, {codecs = &registry},
	)
	testing.expect_value(t, state.call_count, 1)
	testing.expect_value(t, nonzero, Codec_Exact_Root{value = 7})
	diagnostic, diagnostic_ok := nonzero_error.(toml.Unmarshal_Diagnostic)
	testing.expect(t, diagnostic_ok)
	if diagnostic_ok {
		data, data_ok := diagnostic.detail.(toml.Unmarshal_Data_Error)
		testing.expect(t, data_ok)
		if data_ok {
			testing.expect_value(
				t, data.kind, toml.Unmarshal_Data_Error_Kind.Nonzero_Destination_Ownership,
			)
		}
	}
}

Codec_Wrapped :: struct {
	value: i32,
}

Codec_Child_Wrapped :: struct {
	value: i32,
}

Codec_Exact_Optional :: union {
	Codec_Wrapped,
}

Codec_Map_Key :: distinct string

Codec_Selection_Root :: struct {
	direct:        Codec_Wrapped,
	pointer:       ^Codec_Wrapped,
	child_pointer: ^Codec_Child_Wrapped,
	optional:      Codec_Exact_Optional,
	date:     temporal.Local_Date,
	mapping:  map[Codec_Map_Key]i32,
}

Codec_Selection_State :: struct {
	direct_calls:        int,
	pointer_calls:       int,
	child_pointer_calls: int,
	optional_calls:      int,
	temporal_calls: int,
	map_key_calls:  int,
}

unmarshal_selected_value :: proc(
	source: ^toml.Value,
	destination: any,
	user_data: rawptr,
	allocator: mem.Allocator,
	loc: runtime.Source_Code_Location,
) -> toml.Codec_Callback_Error {
	_ = loc
	state := (^Codec_Selection_State)(user_data)
	switch destination.id {
	case typeid_of(Codec_Wrapped):
		state.direct_calls += 1
		value := source^.(toml.Integer)
		(^Codec_Wrapped)(destination.data)^ = {value = i32(value)+10}
	case typeid_of(^Codec_Wrapped):
		state.pointer_calls += 1
		value := source^.(toml.Integer)
		installed, err := new(Codec_Wrapped, allocator)
		if err != nil {return err}
		installed^ = {value = i32(value)+20}
		(^rawptr)(destination.data)^ = installed
	case typeid_of(Codec_Child_Wrapped):
		state.child_pointer_calls += 1
		value := source^.(toml.Integer)
		(^Codec_Child_Wrapped)(destination.data)^ = {value = i32(value)+25}
	case typeid_of(Codec_Exact_Optional):
		state.optional_calls += 1
		value := source^.(toml.Integer)
		(^Codec_Exact_Optional)(destination.data)^ = Codec_Wrapped{value = i32(value)+30}
	case typeid_of(temporal.Local_Date):
		state.temporal_calls += 1
		assert(source^.(toml.String) == "codec-date")
		(^temporal.Local_Date)(destination.data)^ = {2026, 7, 22}
	case typeid_of(Codec_Map_Key):
		state.map_key_calls += 1
		unreachable()
	case:
		unreachable()
	}
	return nil
}

@(test)
unmarshal_codec_selection_precedes_temporals_and_exact_wrappers_but_not_map_keys :: proc(t: ^testing.T) {
	registry, registry_error := toml.init_codec_registry()
	assert(registry_error == nil)
	defer toml.destroy_codec_registry(&registry)
	state: Codec_Selection_State
	registered_types := [?]typeid{
		typeid_of(Codec_Wrapped),
		typeid_of(^Codec_Wrapped),
		typeid_of(Codec_Child_Wrapped),
		typeid_of(Codec_Exact_Optional),
		typeid_of(temporal.Local_Date),
		typeid_of(Codec_Map_Key),
	}
	for id in registered_types {
		assert(toml.register_unmarshaler(
			&registry,
			id,
			{procedure = unmarshal_selected_value, user_data = &state},
		) == nil)
	}

	destination: Codec_Selection_Root
	err := toml.unmarshal_string(
		`direct = 1
pointer = 2
child_pointer = 2
optional = 3
date = "codec-date"
mapping = { key = 4 }
`,
		&destination,
		{codecs = &registry},
	)
	testing.expect(t, err == nil)
	testing.expect_value(t, destination.direct.value, 11)
	testing.expect(t, destination.pointer != nil)
	if destination.pointer != nil {
		testing.expect_value(t, destination.pointer.value, 22)
		assert(free(destination.pointer) == nil)
		destination.pointer = nil
	}
	testing.expect(t, destination.child_pointer != nil)
	if destination.child_pointer != nil {
		testing.expect_value(t, destination.child_pointer.value, 27)
		assert(free(destination.child_pointer) == nil)
		destination.child_pointer = nil
	}
	optional, optional_ok := destination.optional.(Codec_Wrapped)
	testing.expect(t, optional_ok)
	if optional_ok {testing.expect_value(t, optional.value, 33)}
	destination.optional = nil
	testing.expect_value(t, destination.date, temporal.Local_Date{2026, 7, 22})
	testing.expect_value(t, destination.mapping["key"], 4)
	testing.expect_value(t, state.direct_calls, 1)
	testing.expect_value(t, state.pointer_calls, 1)
	testing.expect_value(t, state.child_pointer_calls, 1)
	testing.expect_value(t, state.optional_calls, 1)
	testing.expect_value(t, state.temporal_calls, 1)
	testing.expect_value(t, state.map_key_calls, 0)
	for key in destination.mapping {assert(delete(string(key)) == nil)}
	assert(delete(destination.mapping) == nil)
	destination.mapping = nil
}

Codec_Custom_Root :: distinct i32

unmarshal_custom_root :: proc(
	source: ^toml.Value,
	destination: any,
	user_data: rawptr,
	allocator: mem.Allocator,
	loc: runtime.Source_Code_Location,
) -> toml.Codec_Callback_Error {
	_, _, _ = allocator, loc, user_data
	table := source^.(toml.Table)
	assert(len(table) == 1 && table[0].key == "value")
	(^Codec_Custom_Root)(destination.data)^ = 77
	return nil
}

@(test)
unmarshal_codec_can_bind_an_exact_non_table_root_from_the_root_table :: proc(t: ^testing.T) {
	registry, registry_error := toml.init_codec_registry()
	assert(registry_error == nil)
	defer toml.destroy_codec_registry(&registry)
	assert(toml.register_unmarshaler(
		&registry,
		typeid_of(Codec_Custom_Root),
		{procedure = unmarshal_custom_root},
	) == nil)
	destination: Codec_Custom_Root
	err := toml.unmarshal_string("value = 1\n", &destination, {codecs = &registry})
	testing.expect(t, err == nil)
	testing.expect_value(t, destination, Codec_Custom_Root(77))
}

Codec_Failing_Slot :: struct {
	dirty: i64,
}

Codec_Failure_State :: struct {
	call_count: int,
	code:       u32,
	allocator_error: runtime.Allocator_Error,
}

unmarshal_failing_slot :: proc(
	source: ^toml.Value,
	destination: any,
	user_data: rawptr,
	allocator: mem.Allocator,
	loc: runtime.Source_Code_Location,
) -> toml.Codec_Callback_Error {
	_, _, _ = source, allocator, loc
	state := (^Codec_Failure_State)(user_data)
	state.call_count += 1
	(^Codec_Failing_Slot)(destination.data)^ = {dirty = 0x1234}
	if state.allocator_error != nil {return state.allocator_error}
	return toml.Codec_Callback_Failure{code = state.code}
}

Codec_Failure_Root :: struct {
	first:   string,
	failing: Codec_Failing_Slot,
}

@(test)
unmarshal_codec_failure_zeros_the_complete_slot_and_freezes_diagnostics :: proc(t: ^testing.T) {
	registry, registry_error := toml.init_codec_registry()
	assert(registry_error == nil)
	defer toml.destroy_codec_registry(&registry)
	state := Codec_Failure_State{code = 0x1020_3040}
	assert(toml.register_unmarshaler(
		&registry,
		typeid_of(Codec_Failing_Slot),
		{procedure = unmarshal_failing_slot, user_data = &state},
	) == nil)

	destination: Codec_Failure_Root
	err := toml.unmarshal_string(
		"first = \"owned\"\nfailing = 9\n",
		&destination,
		{codecs = &registry},
	)
	testing.expect_value(t, state.call_count, 1)
	testing.expect_value(t, destination.first, "owned")
	testing.expect_value(t, destination.failing, Codec_Failing_Slot{})
	diagnostic, diagnostic_ok := err.(toml.Unmarshal_Diagnostic)
	testing.expect(t, diagnostic_ok)
	if diagnostic_ok {
		codec_error, codec_ok := diagnostic.detail.(toml.Unmarshal_Codec_Error)
		testing.expect(t, codec_ok)
		if codec_ok {
			testing.expect_value(t, codec_error.registered_type, typeid_of(Codec_Failing_Slot))
			testing.expect_value(t, codec_error.code, u32(0x1020_3040))
		}
		testing.expect(t, diagnostic.source.ok)
		if diagnostic.source.ok {
			testing.expect_value(t, diagnostic.source.value.start.byte, 26)
			testing.expect_value(t, diagnostic.source.value.end.byte, 27)
		}
		name, path_ok := diagnostic.path.segments[0].(string)
		testing.expect(t, path_ok)
		if path_ok {testing.expect_value(t, name, "failing")}
	}
	assert(delete(destination.first) == nil)
	destination.first = ""
}

@(test)
unmarshal_codec_allocator_errors_remain_exact_and_the_slot_is_zero :: proc(t: ^testing.T) {
	registry, registry_error := toml.init_codec_registry()
	assert(registry_error == nil)
	defer toml.destroy_codec_registry(&registry)
	state := Codec_Failure_State{allocator_error = .Invalid_Argument}
	assert(toml.register_unmarshaler(
		&registry,
		typeid_of(Codec_Failing_Slot),
		{procedure = unmarshal_failing_slot, user_data = &state},
	) == nil)
	destination := struct {value: Codec_Failing_Slot}{}
	err := toml.unmarshal_string("value = 1\n", &destination, {codecs = &registry})
	allocator_error, exact := err.(runtime.Allocator_Error)
	testing.expect(t, exact)
	if exact {testing.expect_value(t, allocator_error, runtime.Allocator_Error.Invalid_Argument)}
	testing.expect_value(t, destination.value, Codec_Failing_Slot{})
}

Codec_Owner :: struct {
	text: string,
}

Codec_Map_Value :: struct {
	owned:   Codec_Owner,
	failing: Codec_Failing_Slot,
}

Codec_Map_Root :: struct {
	values: map[string]Codec_Map_Value,
}

Codec_Owner_State :: struct {
	call_count:              int,
	observed:                ^test_support.Observed_Allocator,
	allocation_count_at_call: int,
}

unmarshal_owned_text :: proc(
	source: ^toml.Value,
	destination: any,
	user_data: rawptr,
	allocator: mem.Allocator,
	loc: runtime.Source_Code_Location,
) -> toml.Codec_Callback_Error {
	_ = loc
	state := (^Codec_Owner_State)(user_data)
	state.call_count += 1
	if state.observed != nil {
		state.allocation_count_at_call = state.observed.allocation_request_count
	}
	text := string(source^.(toml.String))
	owned, err := strings.clone(text, allocator)
	if err != nil {return err}
	(^Codec_Owner)(destination.data)^ = {text = owned}
	return nil
}

cleanup_codec_map_root :: proc(root: ^Codec_Map_Root, allocator: mem.Allocator) {
	for key, value in root.values {
		assert(delete(key, allocator) == nil)
		if len(value.owned.text) > 0 {assert(delete(value.owned.text, allocator) == nil)}
	}
	if root.values.allocator.procedure != nil {assert(delete(root.values) == nil)}
	root.values = nil
}

@(test)
unmarshal_codec_success_commits_the_stable_map_entry_before_a_later_failure :: proc(t: ^testing.T) {
	events: [1024]test_support.Allocator_Event
	live: [256]test_support.Live_Allocation
	observed: test_support.Observed_Allocator
	test_support.observed_allocator_init(&observed, context.allocator, events[:], live[:])
	selected := test_support.observed_allocator(&observed)

	registry, registry_error := toml.init_codec_registry()
	assert(registry_error == nil)
	defer toml.destroy_codec_registry(&registry)
	owner_state: Codec_Owner_State
	failure_state := Codec_Failure_State{code = 91}
	assert(toml.register_unmarshaler(
		&registry,
		typeid_of(Codec_Owner),
		{procedure = unmarshal_owned_text, user_data = &owner_state},
	) == nil)
	assert(toml.register_unmarshaler(
		&registry,
		typeid_of(Codec_Failing_Slot),
		{procedure = unmarshal_failing_slot, user_data = &failure_state},
	) == nil)

	destination: Codec_Map_Root
	err := toml.unmarshal_string(
		`[values]
entry = { owned = "kept", failing = 1 }
later = { owned = "never", failing = 2 }
`,
		&destination,
		{codecs = &registry},
		selected,
	)
	_, diagnostic_ok := err.(toml.Unmarshal_Diagnostic)
	testing.expect(t, diagnostic_ok)
	testing.expect_value(t, owner_state.call_count, 1)
	testing.expect_value(t, failure_state.call_count, 1)
	testing.expect_value(t, len(destination.values), 1)
	entry, entry_ok := destination.values["entry"]
	testing.expect(t, entry_ok)
	if entry_ok {
		testing.expect_value(t, entry.owned.text, "kept")
		testing.expect_value(t, entry.failing, Codec_Failing_Slot{})
	}
	_, later_ok := destination.values["later"]
	testing.expect(t, !later_ok)
	cleanup_codec_map_root(&destination, selected)
	testing.expect_value(t, observed.live_count, 0)
	testing.expect_value(t, observed.foreign_release_count, 0)
}

@(test)
unmarshal_direct_map_callback_failure_removes_the_uncommitted_entry :: proc(t: ^testing.T) {
	registry, registry_error := toml.init_codec_registry()
	assert(registry_error == nil)
	defer toml.destroy_codec_registry(&registry)
	state := Codec_Failure_State{code = 17}
	assert(toml.register_unmarshaler(
		&registry,
		typeid_of(Codec_Failing_Slot),
		{procedure = unmarshal_failing_slot, user_data = &state},
	) == nil)
	destination: map[string]Codec_Failing_Slot
	err := toml.unmarshal_string("entry = 1\nlater = 2\n", &destination, {codecs = &registry})
	_, diagnostic_ok := err.(toml.Unmarshal_Diagnostic)
	testing.expect(t, diagnostic_ok)
	testing.expect_value(t, state.call_count, 1)
	testing.expect_value(t, len(destination), 0)
	if destination.allocator.procedure != nil {assert(delete(destination) == nil)}
	destination = nil
}

Codec_Sweep_Value :: struct {
	owned: Codec_Owner,
	later: string,
}

cleanup_codec_sweep_map :: proc(
	mapping: ^map[string]Codec_Sweep_Value,
	allocator: mem.Allocator,
) {
	for key, value in mapping^ {
		assert(delete(key, allocator) == nil)
		if len(value.owned.text) > 0 {assert(delete(value.owned.text, allocator) == nil)}
		if len(value.later) > 0 {assert(delete(value.later, allocator) == nil)}
	}
	if mapping.allocator.procedure != nil {assert(delete(mapping^) == nil)}
	mapping^ = nil
}

@(test)
unmarshal_codec_fail_at_n_preserves_only_opaque_committed_map_entries_and_cleans_temporaries :: proc(t: ^testing.T) {
	saw_failure_after_opaque_success := false
	saw_success := false
	for failure_ordinal in 1..=128 {
		events: [2048]test_support.Allocator_Event
		live: [512]test_support.Live_Allocation
		observed: test_support.Observed_Allocator
		test_support.observed_allocator_init(&observed, context.allocator, events[:], live[:])
		observed.fail_at_allocation = failure_ordinal
		observed.failure_error = .Invalid_Argument
		selected := test_support.observed_allocator(&observed)

		registry, registry_error := toml.init_codec_registry()
		assert(registry_error == nil)
		state: Codec_Owner_State
		assert(toml.register_unmarshaler(
			&registry,
			typeid_of(Codec_Owner),
			{procedure = unmarshal_owned_text, user_data = &state},
		) == nil)
		destination: map[string]Codec_Sweep_Value
		err := toml.unmarshal_string(
			`entry = { owned = "opaque", later = "generic" }
`,
			&destination,
			{codecs = &registry},
			selected,
		)
		if err == nil {
			saw_success = true
		} else {
			if allocator_error, exact := err.(runtime.Allocator_Error); exact {
				testing.expect_value(t, allocator_error, runtime.Allocator_Error.Invalid_Argument)
			}
			if state.call_count == 1 && len(destination) == 1 {
				value := destination["entry"]
				if value.owned.text == "opaque" && value.later == "" {
					saw_failure_after_opaque_success = true
				}
			}
		}
		cleanup_codec_sweep_map(&destination, selected)
		toml.destroy_codec_registry(&registry)
		testing.expect_value(t, observed.live_count, 0)
		testing.expect_value(t, observed.foreign_release_count, 0)
		if saw_failure_after_opaque_success && saw_success {break}
	}
	testing.expect(t, saw_failure_after_opaque_success)
	testing.expect(t, saw_success)
}

Codec_Order_Value :: distinct i32

Codec_Order_State :: struct {
	values:            [3]i32,
	allocation_counts: [3]int,
	count:             int,
	observed:          ^test_support.Observed_Allocator,
}

unmarshal_order_value :: proc(
	source: ^toml.Value,
	destination: any,
	user_data: rawptr,
	allocator: mem.Allocator,
	loc: runtime.Source_Code_Location,
) -> toml.Codec_Callback_Error {
	_, _ = allocator, loc
	state := (^Codec_Order_State)(user_data)
	value := i32(source^.(toml.Integer))
	state.values[state.count] = value
	if state.observed != nil {
		state.allocation_counts[state.count] = state.observed.allocation_request_count
	}
	state.count += 1
	(^Codec_Order_Value)(destination.data)^ = Codec_Order_Value(value)
	return nil
}

@(test)
unmarshal_map_value_callbacks_follow_semantic_insertion_order :: proc(t: ^testing.T) {
	events: [512]test_support.Allocator_Event
	live: [128]test_support.Live_Allocation
	observed: test_support.Observed_Allocator
	test_support.observed_allocator_init(&observed, context.allocator, events[:], live[:])
	selected := test_support.observed_allocator(&observed)
	registry, registry_error := toml.init_codec_registry()
	assert(registry_error == nil)
	defer toml.destroy_codec_registry(&registry)
	state := Codec_Order_State{observed = &observed}
	assert(toml.register_unmarshaler(
		&registry,
		typeid_of(Codec_Order_Value),
		{procedure = unmarshal_order_value, user_data = &state},
	) == nil)
	destination := struct {values: map[string]Codec_Order_Value}{}
	err := toml.unmarshal_string(
		"[values]\nz = 3\na = 1\nm = 2\n",
		&destination,
		{codecs = &registry},
		selected,
	)
	testing.expect(t, err == nil)
	testing.expect_value(t, state.values, [3]i32{3, 1, 2})
	testing.expect_value(t, state.allocation_counts[1], state.allocation_counts[0])
	testing.expect_value(t, state.allocation_counts[2], state.allocation_counts[0])
	for key in destination.values {assert(delete(key, selected) == nil)}
	assert(delete(destination.values) == nil)
	destination.values = nil
	testing.expect_value(t, observed.live_count, 0)
	testing.expect_value(t, observed.foreign_release_count, 0)
}

Codec_Generic_Before_Opaque :: struct {
	generic: string,
	owned:   Codec_Owner,
}

cleanup_generic_before_opaque_map :: proc(
	mapping: ^map[string]Codec_Generic_Before_Opaque,
	allocator: mem.Allocator,
) {
	for key, value in mapping^ {
		assert(delete(key, allocator) == nil)
		if len(value.generic) > 0 {assert(delete(value.generic, allocator) == nil)}
		if len(value.owned.text) > 0 {assert(delete(value.owned.text, allocator) == nil)}
	}
	if mapping.allocator.procedure != nil {assert(delete(mapping^) == nil)}
	mapping^ = nil
}

@(test)
unmarshal_generic_failure_before_codec_success_removes_the_staged_map_entry :: proc(t: ^testing.T) {
	input := `entry = { generic = "package", owned = "opaque" }
`
	baseline_events: [1024]test_support.Allocator_Event
	baseline_live: [256]test_support.Live_Allocation
	baseline_observed: test_support.Observed_Allocator
	test_support.observed_allocator_init(
		&baseline_observed, context.allocator, baseline_events[:], baseline_live[:],
	)
	baseline_allocator := test_support.observed_allocator(&baseline_observed)
	baseline_registry, baseline_registry_error := toml.init_codec_registry()
	assert(baseline_registry_error == nil)
	baseline_state := Codec_Owner_State{observed = &baseline_observed}
	assert(toml.register_unmarshaler(
		&baseline_registry,
		typeid_of(Codec_Owner),
		{procedure = unmarshal_owned_text, user_data = &baseline_state},
	) == nil)
	baseline: map[string]Codec_Generic_Before_Opaque
	baseline_error := toml.unmarshal_string(
		input, &baseline, {codecs = &baseline_registry}, baseline_allocator,
	)
	assert(baseline_error == nil)
	assert(baseline_state.call_count == 1)
	generic_allocation_ordinal := baseline_state.allocation_count_at_call
	assert(generic_allocation_ordinal > 0)
	cleanup_generic_before_opaque_map(&baseline, baseline_allocator)
	toml.destroy_codec_registry(&baseline_registry)
	testing.expect_value(t, baseline_observed.live_count, 0)

	events: [1024]test_support.Allocator_Event
	live: [256]test_support.Live_Allocation
	observed: test_support.Observed_Allocator
	test_support.observed_allocator_init(&observed, context.allocator, events[:], live[:])
	observed.fail_at_allocation = generic_allocation_ordinal
	observed.failure_error = .Invalid_Argument
	selected := test_support.observed_allocator(&observed)
	registry, registry_error := toml.init_codec_registry()
	assert(registry_error == nil)
	state := Codec_Owner_State{observed = &observed}
	assert(toml.register_unmarshaler(
		&registry,
		typeid_of(Codec_Owner),
		{procedure = unmarshal_owned_text, user_data = &state},
	) == nil)
	destination: map[string]Codec_Generic_Before_Opaque
	err := toml.unmarshal_string(input, &destination, {codecs = &registry}, selected)
	allocator_error, exact := err.(runtime.Allocator_Error)
	testing.expect(t, exact)
	if exact {testing.expect_value(t, allocator_error, runtime.Allocator_Error.Invalid_Argument)}
	testing.expect_value(t, state.call_count, 0)
	testing.expect_value(t, len(destination), 0)
	cleanup_generic_before_opaque_map(&destination, selected)
	toml.destroy_codec_registry(&registry)
	testing.expect_value(t, observed.live_count, 0)
	testing.expect_value(t, observed.foreign_release_count, 0)
}

@(test)
unmarshal_codec_map_commit_works_with_an_external_lifetime_allocator :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	external: test_support.External_Lifetime_Allocator
	test_support.external_lifetime_allocator_init(
		&external, mem.dynamic_arena_allocator(&arena), true,
	)
	selected := test_support.external_lifetime_allocator(&external)
	registry, registry_error := toml.init_codec_registry()
	assert(registry_error == nil)
	owner_state: Codec_Owner_State
	failure_state := Codec_Failure_State{code = 22}
	assert(toml.register_unmarshaler(
		&registry,
		typeid_of(Codec_Owner),
		{procedure = unmarshal_owned_text, user_data = &owner_state},
	) == nil)
	assert(toml.register_unmarshaler(
		&registry,
		typeid_of(Codec_Failing_Slot),
		{procedure = unmarshal_failing_slot, user_data = &failure_state},
	) == nil)
	destination: Codec_Map_Root
	err := toml.unmarshal_string(
		"[values]\nentry = { owned = \"kept\", failing = 1 }\n",
		&destination,
		{codecs = &registry},
		selected,
	)
	_, diagnostic_ok := err.(toml.Unmarshal_Diagnostic)
	testing.expect(t, diagnostic_ok)
	testing.expect_value(t, len(destination.values), 1)
	entry := destination.values["entry"]
	testing.expect_value(t, entry.owned.text, "kept")
	testing.expect_value(t, entry.failing, Codec_Failing_Slot{})
	destination = {}
	toml.destroy_codec_registry(&registry)
	mem.dynamic_arena_destroy(&arena)
	testing.expect_value(t, external.release_attempt_count, 0)
}

Codec_Late_Preflight_Root :: struct {
	codec: Codec_Named_Integer,
	late:  i8,
}

Codec_Any_Root :: struct {
	payload: any,
}

Codec_Never_State :: struct {
	call_count: int,
}

unmarshal_never_called :: proc(
	source: ^toml.Value,
	destination: any,
	user_data: rawptr,
	allocator: mem.Allocator,
	loc: runtime.Source_Code_Location,
) -> toml.Codec_Callback_Error {
	_, _, _, _ = source, destination, allocator, loc
	state := (^Codec_Never_State)(user_data)
	state.call_count += 1
	return nil
}

@(test)
unmarshal_completes_generic_preflight_before_callbacks_and_never_uses_an_any_codec :: proc(t: ^testing.T) {
	registry, registry_error := toml.init_codec_registry()
	assert(registry_error == nil)
	defer toml.destroy_codec_registry(&registry)
	codec_state: Codec_Invocation_State
	any_state: Codec_Never_State
	assert(toml.register_unmarshaler(
		&registry,
		typeid_of(Codec_Named_Integer),
		{procedure = unmarshal_named_integer, user_data = &codec_state},
	) == nil)
	assert(toml.register_unmarshaler(
		&registry,
		typeid_of(any),
		{procedure = unmarshal_never_called, user_data = &any_state},
	) == nil)
	late := Codec_Late_Preflight_Root{late = 7}
	late_before := late
	late_error := toml.unmarshal_string(
		"codec = 41\nlate = 128\n", &late, {codecs = &registry},
	)
	_, late_diagnostic := late_error.(toml.Unmarshal_Diagnostic)
	testing.expect(t, late_diagnostic)
	testing.expect_value(t, codec_state.call_count, 0)
	testing.expect_value(t, late, late_before)

	any_destination: Codec_Any_Root
	any_error := toml.unmarshal_string(
		"payload = 1\n", &any_destination, {codecs = &registry},
	)
	any_diagnostic, any_ok := any_error.(toml.Unmarshal_Diagnostic)
	testing.expect(t, any_ok)
	if any_ok {
		data, data_ok := any_diagnostic.detail.(toml.Unmarshal_Data_Error)
		testing.expect(t, data_ok)
		if data_ok {
			testing.expect_value(
				t, data.kind, toml.Unmarshal_Data_Error_Kind.Unsupported_Destination_Type,
			)
		}
	}
	testing.expect_value(t, any_state.call_count, 0)
}

@(test)
unmarshal_array_element_callbacks_follow_index_order :: proc(t: ^testing.T) {
	registry, registry_error := toml.init_codec_registry()
	assert(registry_error == nil)
	defer toml.destroy_codec_registry(&registry)
	state: Codec_Order_State
	assert(toml.register_unmarshaler(
		&registry,
		typeid_of(Codec_Order_Value),
		{procedure = unmarshal_order_value, user_data = &state},
	) == nil)
	destination := struct {values: []Codec_Order_Value}{}
	err := toml.unmarshal_string(
		"values = [3, 1, 2]\n", &destination, {codecs = &registry},
	)
	testing.expect(t, err == nil)
	testing.expect_value(t, state.values, [3]i32{3, 1, 2})
	assert(delete(destination.values) == nil)
	destination.values = nil
}

marshal_paired_integer :: proc(
	source: any,
	user_data: rawptr,
	allocator: mem.Allocator,
	loc: runtime.Source_Code_Location,
) -> (toml.Value, toml.Codec_Callback_Error) {
	_, _, _, _ = source, user_data, allocator, loc
	return toml.Value(toml.Integer(9)), nil
}

@(test)
unmarshal_and_marshal_codecs_for_one_exact_type_are_directionally_paired :: proc(t: ^testing.T) {
	registry, registry_error := toml.init_codec_registry()
	assert(registry_error == nil)
	defer toml.destroy_codec_registry(&registry)
	state: Codec_Invocation_State
	assert(toml.register_marshaler(
		&registry,
		typeid_of(Codec_Named_Integer),
		{procedure = marshal_paired_integer},
	) == nil)
	assert(toml.register_unmarshaler(
		&registry,
		typeid_of(Codec_Named_Integer),
		{procedure = unmarshal_named_integer, user_data = &state},
	) == nil)
	bytes, marshal_error := toml.marshal(Codec_Exact_Root{value = 7}, {codecs = &registry})
	testing.expect(t, marshal_error == nil)
	if marshal_error == nil {
		testing.expect_value(t, string(bytes), "\"value\" = 9\n")
		assert(delete(bytes) == nil)
	}
	destination: Codec_Exact_Root
	unmarshal_error := toml.unmarshal_string("value = 41\n", &destination, {codecs = &registry})
	testing.expect(t, unmarshal_error == nil)
	testing.expect_value(t, destination.value, Codec_Named_Integer(42))
}

Codec_Concurrent_State :: struct {
	registry: ^toml.Codec_Registry,
	success:  bool,
}

unmarshal_concurrent_integer :: proc(
	source: ^toml.Value,
	destination: any,
	user_data: rawptr,
	allocator: mem.Allocator,
	loc: runtime.Source_Code_Location,
) -> toml.Codec_Callback_Error {
	_, _, _ = user_data, allocator, loc
	(^Codec_Named_Integer)(destination.data)^ = Codec_Named_Integer(source^.(toml.Integer))
	return nil
}

codec_unmarshal_concurrent_worker :: proc(data: rawptr) {
	state := (^Codec_Concurrent_State)(data)
	state.success = true
	for _ in 0..<250 {
		destination: Codec_Exact_Root
		err := toml.unmarshal_string(
			"value = 41\n", &destination, {codecs = state.registry},
		)
		if err != nil || destination.value != 41 {
			state.success = false
			return
		}
	}
}

@(test)
unmarshal_codec_frozen_registry_supports_concurrent_calls :: proc(t: ^testing.T) {
	registry, registry_error := toml.init_codec_registry()
	assert(registry_error == nil)
	assert(toml.register_unmarshaler(
		&registry,
		typeid_of(Codec_Named_Integer),
		{procedure = unmarshal_concurrent_integer},
	) == nil)
	THREAD_COUNT :: 4
	states: [THREAD_COUNT]Codec_Concurrent_State
	threads: [THREAD_COUNT]^thread.Thread
	for index in 0..<THREAD_COUNT {
		states[index].registry = &registry
		threads[index] = thread.create_and_start_with_data(
			&states[index], codec_unmarshal_concurrent_worker,
		)
		testing.expect(t, threads[index] != nil)
	}
	for worker in threads {
		if worker != nil {thread.destroy(worker)}
	}
	for state in states {testing.expect(t, state.success)}
	toml.destroy_codec_registry(&registry)
}

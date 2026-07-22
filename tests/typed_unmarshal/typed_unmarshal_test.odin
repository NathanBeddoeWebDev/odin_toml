package typed_unmarshal_test

import "base:runtime"
import "core:mem"
import "core:testing"
import toml "../.."
import temporal "../../temporal"
import test_support "../support"

Named_Bool :: distinct bool
Named_Int :: distinct i16
Named_Uint :: distinct u16
Named_Float :: distinct f32

Machine_Integers :: struct {
	signed:   int,
	unsigned: uint,
	address:  uintptr,
}

Nested :: struct {
	value: Named_Int,
}

Scalar_Destination :: struct {
	enabled: Named_Bool,
	count: Named_Int,
	positive: Named_Uint,
	ratio: Named_Float,
	date: temporal.Local_Date,
	nested: Nested,
	defaulted: i32,
	ignored: string `toml:"-"`,
}

@(test)
unmarshal_machine_sized_integer_kinds :: proc(t: ^testing.T) {
	destination: Machine_Integers
	err := toml.unmarshal_string(
		"signed = -1\nunsigned = 2\naddress = 3\n",
		&destination,
	)
	testing.expect(t, err == nil)
	testing.expect_value(t, destination, Machine_Integers{-1, 2, 3})
}

@(test)
unmarshal_scalar_structs_through_both_public_forms :: proc(t: ^testing.T) {
	input := `enabled = true
count = -12
positive = 65535
ratio = 1.5
date = 2026-07-04
nested = { value = 42 }
ignored = "source"
`
	expected := Scalar_Destination{
		enabled = true,
		count = -12,
		positive = 65535,
		ratio = 1.5,
		date = {2026, 7, 4},
		nested = {42},
		defaulted = 91,
		ignored = "application",
	}

	from_string := Scalar_Destination{defaulted = 91, ignored = "application"}
	string_error := toml.unmarshal_string(input, &from_string)
	testing.expect(t, string_error == nil)
	testing.expect_value(t, from_string, expected)

	from_bytes := Scalar_Destination{defaulted = 91, ignored = "application"}
	bytes_error := toml.unmarshal(transmute([]byte)input, &from_bytes)
	testing.expect(t, bytes_error == nil)
	testing.expect_value(t, from_bytes, expected)
}

Unknown_Nested :: struct {known: i32}
Unknown_Root :: struct {
	first: i32,
	nested: Unknown_Nested,
}

@(test)
unmarshal_rejects_first_recursive_unknown_without_mutation :: proc(t: ^testing.T) {
	input := `first = 1
nested = { known = 2, unknown = 3 }
later = 4
`
	destination := Unknown_Root{first = 77, nested = {88}}
	before := destination
	err := toml.unmarshal_string(input, &destination, {reject_unknown_fields = true})
	testing.expect_value(t, destination, before)
	diagnostic, ok := err.(toml.Unmarshal_Diagnostic)
	testing.expect(t, ok)
	if !ok {
		return
	}
	data, data_ok := diagnostic.detail.(toml.Unmarshal_Data_Error)
	testing.expect(t, data_ok)
	if data_ok {
		testing.expect_value(t, data.kind, toml.Unmarshal_Data_Error_Kind.Unknown_Field)
	}
	testing.expect(t, diagnostic.source.ok)
	if diagnostic.source.ok {
		testing.expect_value(t, diagnostic.source.value.start.byte, 32)
		testing.expect_value(t, diagnostic.source.value.end.byte, 39)
	}
}

Range_Destination :: struct {value: i8}

@(test)
unmarshal_wraps_parse_errors_and_keeps_preflight_failures_immutable :: proc(t: ^testing.T) {
	parse_destination := Range_Destination{19}
	parse_error := toml.unmarshal_string("value = [", &parse_destination)
	testing.expect_value(t, parse_destination, Range_Destination{19})
	wrapped, wrapped_ok := parse_error.(toml.Unmarshal_Parse_Error)
	testing.expect(t, wrapped_ok)
	if wrapped_ok {
		_, exact_parse := wrapped.error.(toml.Parse_Diagnostic)
		testing.expect(t, exact_parse)
	}

	range_destination := Range_Destination{19}
	range_error := toml.unmarshal_string("value = 128\n", &range_destination)
	testing.expect_value(t, range_destination, Range_Destination{19})
	diagnostic, diagnostic_ok := range_error.(toml.Unmarshal_Diagnostic)
	testing.expect(t, diagnostic_ok)
	if !diagnostic_ok {
		return
	}
	data, data_ok := diagnostic.detail.(toml.Unmarshal_Data_Error)
	testing.expect(t, data_ok)
	if data_ok {
		testing.expect_value(t, data.kind, toml.Unmarshal_Data_Error_Kind.Integer_Out_Of_Range)
		testing.expect_value(t, data.destination_type, typeid_of(i8))
	}
	testing.expect(t, diagnostic.source.ok)
	testing.expect_value(t, diagnostic.source.value.start.byte, 8)
	testing.expect_value(t, diagnostic.source.value.end.byte, 11)
}

Flattened :: struct {
	renamed: i32 `toml:"source-name"`,
}

Projection_Destination :: struct {
	first: i32,
	using _: Flattened,
	missing_text: string,
	ignored_owner: string `toml:"-"`,
}

Malformed_Destination :: struct {value: i32 `toml:"value,unknown"`}
Duplicate_Tag_Destination :: struct {value: i32 `toml:"first" toml:"second"`}
Malformed_List_Destination :: struct {value: i32 `toml:"value" malformed`}
Invalid_Flatten_Destination :: struct {
	using _: Flattened `toml:"renamed"`,
}
Collision_Destination :: struct {
	first: i32 `toml:"same"`,
	second: i32 `toml:"same"`,
}
Unsupported_Missing :: struct {callback: proc()}

@(test)
unmarshal_validates_projection_but_preserves_missing_and_ignored_ownership :: proc(t: ^testing.T) {
	destination := Projection_Destination{
		first = 70,
		renamed = 71,
		missing_text = "application-default",
		ignored_owner = "application-owner",
	}
	err := toml.unmarshal_string("first = 1\nsource-name = 2\n", &destination)
	testing.expect(t, err == nil)
	testing.expect_value(t, destination.first, 1)
	testing.expect_value(t, destination.renamed, 2)
	testing.expect_value(t, destination.missing_text, "application-default")
	testing.expect_value(t, destination.ignored_owner, "application-owner")

	malformed := Malformed_Destination{19}
	malformed_before := malformed
	malformed_error := toml.unmarshal_string("value = 1\n", &malformed)
	testing.expect_value(t, malformed, malformed_before)
	malformed_diagnostic, malformed_ok := malformed_error.(toml.Unmarshal_Diagnostic)
	testing.expect(t, malformed_ok)
	if malformed_ok {
		data, ok := malformed_diagnostic.detail.(toml.Unmarshal_Data_Error)
		testing.expect(t, ok)
		if ok {
			testing.expect_value(t, data.kind, toml.Unmarshal_Data_Error_Kind.Malformed_Tag)
			testing.expect_value(t, data.destination_type, typeid_of(i32))
		}
		testing.expect(t, !malformed_diagnostic.source.ok)
	}

	duplicate_tag: Duplicate_Tag_Destination
	duplicate_error := toml.unmarshal_string("first = 1\n", &duplicate_tag)
	duplicate_diagnostic, duplicate_ok := duplicate_error.(toml.Unmarshal_Diagnostic)
	testing.expect(t, duplicate_ok)
	if duplicate_ok {
		data, ok := duplicate_diagnostic.detail.(toml.Unmarshal_Data_Error)
		testing.expect(t, ok)
		if ok {
			testing.expect_value(t, data.kind, toml.Unmarshal_Data_Error_Kind.Malformed_Tag)
		}
	}

	malformed_list: Malformed_List_Destination
	malformed_list_error := toml.unmarshal_string("value = 1\n", &malformed_list)
	malformed_list_diagnostic, malformed_list_ok := malformed_list_error.(toml.Unmarshal_Diagnostic)
	testing.expect(t, malformed_list_ok)
	if malformed_list_ok {
		data, ok := malformed_list_diagnostic.detail.(toml.Unmarshal_Data_Error)
		testing.expect(t, ok)
		if ok {
			testing.expect_value(t, data.kind, toml.Unmarshal_Data_Error_Kind.Malformed_Tag)
		}
	}

	invalid_flatten: Invalid_Flatten_Destination
	flatten_error := toml.unmarshal_string("source-name = 1\n", &invalid_flatten)
	flatten_diagnostic, flatten_ok := flatten_error.(toml.Unmarshal_Diagnostic)
	testing.expect(t, flatten_ok)
	if flatten_ok {
		data, ok := flatten_diagnostic.detail.(toml.Unmarshal_Data_Error)
		testing.expect(t, ok)
		if ok {
			testing.expect_value(t, data.kind, toml.Unmarshal_Data_Error_Kind.Malformed_Tag)
		}
	}

	collision := Collision_Destination{11, 12}
	collision_before := collision
	collision_error := toml.unmarshal_string("same = 1\n", &collision)
	testing.expect_value(t, collision, collision_before)
	collision_diagnostic, collision_ok := collision_error.(toml.Unmarshal_Diagnostic)
	testing.expect(t, collision_ok)
	if collision_ok {
		data, ok := collision_diagnostic.detail.(toml.Unmarshal_Data_Error)
		testing.expect(t, ok)
		if ok {
			testing.expect_value(t, data.kind, toml.Unmarshal_Data_Error_Kind.Effective_Field_Name_Collision)
		}
	}

	unsupported: Unsupported_Missing
	unsupported_error := toml.unmarshal_string("", &unsupported)
	unsupported_diagnostic, unsupported_ok := unsupported_error.(toml.Unmarshal_Diagnostic)
	testing.expect(t, unsupported_ok)
	if unsupported_ok {
		data, ok := unsupported_diagnostic.detail.(toml.Unmarshal_Data_Error)
		testing.expect(t, ok)
		if ok {
			testing.expect_value(t, data.kind, toml.Unmarshal_Data_Error_Kind.Unsupported_Destination_Type)
			testing.expect_value(t, data.destination_type, typeid_of(proc()))
		}
	}
}

Deferred_String :: struct {text: string}
Kind_Mismatch :: struct {value: i32}
Temporal_Mismatch :: struct {value: temporal.Local_Date}
Owned_Array_Child :: struct {values: [1]string}

@(test)
unmarshal_reports_deferred_owning_slots_and_stable_diagnostics :: proc(t: ^testing.T) {
	owned := Deferred_String{text = "application"}
	owned_before := owned
	owned_error := toml.unmarshal_string("text = \"source\"\n", &owned)
	testing.expect_value(t, owned, owned_before)
	owned_diagnostic, owned_ok := owned_error.(toml.Unmarshal_Diagnostic)
	testing.expect(t, owned_ok)
	if owned_ok {
		data, ok := owned_diagnostic.detail.(toml.Unmarshal_Data_Error)
		testing.expect(t, ok)
		if ok {
			testing.expect_value(t, data.kind, toml.Unmarshal_Data_Error_Kind.Nonzero_Destination_Ownership)
		}
	}

	clean: Deferred_String
	clean_error := toml.unmarshal_string("text = \"source\"\n", &clean)
	testing.expect_value(t, clean, Deferred_String{})
	clean_diagnostic, clean_ok := clean_error.(toml.Unmarshal_Diagnostic)
	testing.expect(t, clean_ok)
	if clean_ok {
		data, ok := clean_diagnostic.detail.(toml.Unmarshal_Data_Error)
		testing.expect(t, ok)
		if ok {
			testing.expect_value(t, data.kind, toml.Unmarshal_Data_Error_Kind.Unsupported_Destination_Type)
		}
	}

	temporal_destination := Temporal_Mismatch{value = {2026, 1, 1}}
	temporal_before := temporal_destination
	temporal_error := toml.unmarshal_string("value = 12:00:00\n", &temporal_destination)
	testing.expect_value(t, temporal_destination, temporal_before)
	temporal_diagnostic, temporal_ok := temporal_error.(toml.Unmarshal_Diagnostic)
	testing.expect(t, temporal_ok)
	if temporal_ok {
		data, ok := temporal_diagnostic.detail.(toml.Unmarshal_Data_Error)
		testing.expect(t, ok)
		if ok {
			testing.expect_value(t, data.kind, toml.Unmarshal_Data_Error_Kind.Source_Destination_Kind_Mismatch)
			testing.expect_value(t, data.source_kind, toml.Value_Kind.Local_Time)
		}
	}

	owned_array := Owned_Array_Child{values = {"application"}}
	owned_array_before := owned_array
	owned_array_error := toml.unmarshal_string("values = [\"source\"]\n", &owned_array)
	testing.expect_value(t, owned_array, owned_array_before)
	owned_array_diagnostic, owned_array_ok := owned_array_error.(toml.Unmarshal_Diagnostic)
	testing.expect(t, owned_array_ok)
	if owned_array_ok {
		data, ok := owned_array_diagnostic.detail.(toml.Unmarshal_Data_Error)
		testing.expect(t, ok)
		if ok {
			testing.expect_value(t, data.kind, toml.Unmarshal_Data_Error_Kind.Nonzero_Destination_Ownership)
		}
	}

	mutable_input := make([]byte, len("value = true\n"))
	copy(mutable_input, "value = true\n")
	defer delete(mutable_input)
	mismatch := Kind_Mismatch{31}
	mismatch_error := toml.unmarshal(mutable_input, &mismatch)
	for &byte in mutable_input {
		byte = 'x'
	}
	testing.expect_value(t, mismatch, Kind_Mismatch{31})
	mismatch_diagnostic, mismatch_ok := mismatch_error.(toml.Unmarshal_Diagnostic)
	testing.expect(t, mismatch_ok)
	if mismatch_ok {
		data, ok := mismatch_diagnostic.detail.(toml.Unmarshal_Data_Error)
		testing.expect(t, ok)
		if ok {
			testing.expect_value(t, data.kind, toml.Unmarshal_Data_Error_Kind.Source_Destination_Kind_Mismatch)
		}
		testing.expect(t, mismatch_diagnostic.source.ok)
		testing.expect_value(t, mismatch_diagnostic.source.value.start.byte, 8)
		name, path_ok := mismatch_diagnostic.path.segments[0].(string)
		testing.expect(t, path_ok)
		if path_ok {
			testing.expect_value(t, name, "value")
		}
	}
}

Config_Destination :: struct {value: i32}

@(test)
unmarshal_root_kind_float_range_and_fixed_length_fail_immutably :: proc(t: ^testing.T) {
	scalar_root := i32(17)
	root_error := toml.unmarshal_string("value = 1\n", &scalar_root)
	testing.expect_value(t, scalar_root, i32(17))
	root_diagnostic, root_ok := root_error.(toml.Unmarshal_Diagnostic)
	testing.expect(t, root_ok)
	if root_ok {
		data, ok := root_diagnostic.detail.(toml.Unmarshal_Data_Error)
		testing.expect(t, ok)
		if ok {
			testing.expect_value(t, data.kind, toml.Unmarshal_Data_Error_Kind.Invalid_Root_Shape)
		}
	}

	float_destination := struct {value: f32}{value = 7}
	float_before := float_destination
	float_error := toml.unmarshal_string("value = 1e100\n", &float_destination)
	testing.expect_value(t, float_destination, float_before)
	float_diagnostic, float_ok := float_error.(toml.Unmarshal_Diagnostic)
	testing.expect(t, float_ok)
	if float_ok {
		data, ok := float_diagnostic.detail.(toml.Unmarshal_Data_Error)
		testing.expect(t, ok)
		if ok {
			testing.expect_value(t, data.kind, toml.Unmarshal_Data_Error_Kind.Float_Out_Of_Range)
		}
	}

	array_destination := struct {values: [2]i32}{values = {7, 8}}
	array_before := array_destination
	array_error := toml.unmarshal_string("values = [1]\n", &array_destination)
	testing.expect_value(t, array_destination, array_before)
	array_diagnostic, array_ok := array_error.(toml.Unmarshal_Diagnostic)
	testing.expect(t, array_ok)
	if array_ok {
		data, ok := array_diagnostic.detail.(toml.Unmarshal_Data_Error)
		testing.expect(t, ok)
		if ok {
			testing.expect_value(t, data.kind, toml.Unmarshal_Data_Error_Kind.Fixed_Array_Length_Mismatch)
			testing.expect_value(t, data.expected_count, 2)
			testing.expect_value(t, data.actual_count, 1)
		}
	}
}

AoT_Item :: struct {value: i8}
AoT_Destination :: struct {items: [2]AoT_Item}

@(test)
unmarshal_array_of_tables_diagnostic_uses_exact_element_value_range :: proc(t: ^testing.T) {
	input := "[[items]]\nvalue = 1\n[[items]]\nvalue = 128\n"
	destination: AoT_Destination
	err := toml.unmarshal_string(input, &destination)
	testing.expect_value(t, destination, AoT_Destination{})
	diagnostic, ok := err.(toml.Unmarshal_Diagnostic)
	testing.expect(t, ok)
	if !ok {
		return
	}
	data, data_ok := diagnostic.detail.(toml.Unmarshal_Data_Error)
	testing.expect(t, data_ok)
	if data_ok {
		testing.expect_value(t, data.kind, toml.Unmarshal_Data_Error_Kind.Integer_Out_Of_Range)
	}
	testing.expect(t, diagnostic.source.ok)
	if diagnostic.source.ok {
		testing.expect_value(t, diagnostic.source.value.start.byte, 38)
		testing.expect_value(t, diagnostic.source.value.end.byte, 41)
	}
}

@(test)
unmarshal_configuration_precedes_parsing :: proc(t: ^testing.T) {
	destination := Config_Destination{22}
	invalid_allocator := mem.Allocator{}
	allocator_error := toml.unmarshal_string("not toml", &destination, allocator = invalid_allocator)
	testing.expect_value(t, allocator_error, toml.Unmarshal_Configuration_Error.Invalid_Allocator)

	depth_error := toml.unmarshal_string("not toml", &destination, {max_depth = 257})
	testing.expect_value(t, depth_error, toml.Unmarshal_Configuration_Error.Invalid_Max_Depth)

	nil_destination: ^Config_Destination
	nil_error := toml.unmarshal_string("not toml", nil_destination)
	testing.expect_value(t, nil_error, toml.Unmarshal_Configuration_Error.Nil_Destination)

	invalid_registry: toml.Codec_Registry
	registry_error := toml.unmarshal_string(
		"not toml", &destination, {codecs = &invalid_registry},
	)
	testing.expect_value(t, registry_error, toml.Unmarshal_Configuration_Error.Invalid_Codec_Registry)
	testing.expect_value(t, destination, Config_Destination{22})
}

@(test)
unmarshal_allocator_failures_leave_destination_and_package_ownership_clean :: proc(t: ^testing.T) {
	saw_wrapped_parse_failure := false
	saw_outer_preflight_failure := false
	saw_success := false
	for failure_ordinal in 1..=96 {
		events: [256]test_support.Allocator_Event
		live: [128]test_support.Live_Allocation
		state: test_support.Observed_Allocator
		test_support.observed_allocator_init(&state, context.allocator, events[:], live[:])
		state.fail_at_allocation = failure_ordinal
		allocator := test_support.observed_allocator(&state)
		destination := Scalar_Destination{defaulted = 91, ignored = "application"}
		before := destination
		err := toml.unmarshal_string(
			"enabled = true\ncount = 1\npositive = 2\nratio = 3.0\ndate = 2026-07-04\nnested = { value = 4 }\n",
			&destination,
			allocator = allocator,
		)
		if err == nil {
			saw_success = true
			testing.expect_value(t, destination.count, Named_Int(1))
		} else {
			testing.expect_value(t, destination, before)
			if _, wrapped := err.(toml.Unmarshal_Parse_Error); wrapped {
				saw_wrapped_parse_failure = true
			} else {
				_, exact_allocator := err.(runtime.Allocator_Error)
				testing.expect(t, exact_allocator)
				saw_outer_preflight_failure = saw_outer_preflight_failure || exact_allocator
			}
		}
		testing.expect_value(t, state.live_count, 0)
		testing.expect_value(t, state.foreign_release_count, 0)
	}
	testing.expect(t, saw_wrapped_parse_failure)
	testing.expect(t, saw_outer_preflight_failure)
	testing.expect(t, saw_success)
}

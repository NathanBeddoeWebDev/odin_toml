package main

import "core:strings"
import "core:testing"

@(test)
test_encoder_adapter_builds_semantic_document_and_unparses_canonically :: proc(t: ^testing.T) {
	builder, builder_error := strings.builder_make()
	testing.expect(t, builder_error == nil)
	if builder_error != nil {
		return
	}
	defer strings.builder_destroy(&builder)

	input := `{"message":{"type":"string","value":"hello"},"answer":{"type":"integer","value":"42"}}`
	err := encode_to_writer(transmute([]byte)input, strings.to_writer(&builder))
	testing.expect(t, err == nil)
	testing.expect_value(
		t,
		strings.to_string(builder),
		`"answer" = 42
"message" = "hello"
`,
	)
}

@(test)
test_encoder_adapter_preserves_array_order_and_all_protocol_kinds :: proc(t: ^testing.T) {
	builder, builder_error := strings.builder_make()
	assert(builder_error == nil)
	defer strings.builder_destroy(&builder)

	input := `{"values":[{"type":"bool","value":"true"},{"type":"float","value":"-0"},{"type":"datetime","value":"1979-05-27T07:32:00Z"},{"type":"datetime-local","value":"1979-05-27T07:32:00"},{"type":"date-local","value":"1979-05-27"},{"type":"time-local","value":"07:32:00"}],"nested":{"empty":{},"items":[{"name":{"type":"string","value":"first"}},{"name":{"type":"string","value":"second"}}]}}`
	err := encode_to_writer(transmute([]byte)input, strings.to_writer(&builder))
	testing.expect(t, err == nil)
	testing.expect_value(
		t,
		strings.to_string(builder),
		`"nested" = { "empty" = {}, "items" = [{ "name" = "first" }, { "name" = "second" }] }
"values" = [true, -0.0, 1979-05-27T07:32:00Z, 1979-05-27T07:32:00, 1979-05-27, 07:32:00]
`,
	)
}

@(test)
test_encoder_adapter_rejects_malformed_and_unsupported_protocol_without_output :: proc(t: ^testing.T) {
	cases := [?]struct {
		input:    string,
		expected: Adapter_Error_Kind,
	}{
		{``, .Malformed_Input},
		{`{`, .Malformed_Input},
		{`{} {}`, .Malformed_Input},
		{`{"a":1}`, .Unsupported_Protocol_Value},
		{`{"a":{"type":"integer","value":1}}`, .Unsupported_Protocol_Value},
		{`{"a":{"type":{"type":"string","value":"table"},"value":{"type":"integer","value":"1"}}}`, .Unsupported_Protocol_Value},
		{`{"a":{"type":"integer","value":"1"},"a":{"type":"integer","value":"2"}}`, .Unsupported_Protocol_Value},
		{`{"":{"type":"integer","value":"1"},"":{"type":"integer","value":"2"}}`, .Unsupported_Protocol_Value},
		{`{"a":{"type":"integer","value":"1.0"}}`, .Unsupported_Protocol_Value},
		{`{"a":{"type":"float","value":"1e9999"}}`, .Unsupported_Protocol_Value},
		{`{"a":{"type":"bool","value":"TRUE"}}`, .Unsupported_Protocol_Value},
		{`{"a":{"type":"date-local","value":"2023-02-29"}}`, .Unsupported_Protocol_Value},
		{`{"a":{"type":"unknown","value":"x"}}`, .Unsupported_Protocol_Value},
		{`[]`, .Unsupported_Protocol_Value},
	}

	for test_case in cases {
		builder, builder_error := strings.builder_make()
		assert(builder_error == nil)
		err := encode_to_writer(
			transmute([]byte)test_case.input,
			strings.to_writer(&builder),
		)
		kind, ok := err.(Adapter_Error_Kind)
		testing.expect(t, ok)
		if ok {
			testing.expect_value(t, kind, test_case.expected)
		}
		testing.expect_value(t, strings.to_string(builder), "")
		strings.builder_destroy(&builder)
	}
}

@(test)
test_encoder_adapter_preserves_empty_keys :: proc(t: ^testing.T) {
	builder, builder_error := strings.builder_make()
	assert(builder_error == nil)
	defer strings.builder_destroy(&builder)

	input := `{"":{"type":"string","value":"blank"}}`
	err := encode_to_writer(
		transmute([]byte)input,
		strings.to_writer(&builder),
	)
	testing.expect(t, err == nil)
	testing.expect_value(t, strings.to_string(builder), `"" = "blank"
`)
}

@(test)
test_encoder_adapter_treats_only_exact_type_value_objects_as_scalars :: proc(t: ^testing.T) {
	builder, builder_error := strings.builder_make()
	assert(builder_error == nil)
	defer strings.builder_destroy(&builder)

	input := `{"only_type":{"type":{"type":"string","value":"table"}},"three":{"type":{"type":"string","value":"table"},"value":{"type":"string","value":"member"},"extra":{"type":"integer","value":"1"}}}`
	err := encode_to_writer(transmute([]byte)input, strings.to_writer(&builder))
	testing.expect(t, err == nil)
	testing.expect_value(
		t,
		strings.to_string(builder),
		`"only_type" = { "type" = "table" }
"three" = { "extra" = 1, "type" = "table", "value" = "member" }
`,
	)
}

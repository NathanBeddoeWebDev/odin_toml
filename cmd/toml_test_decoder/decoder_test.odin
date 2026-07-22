package main

import "core:strings"
import "core:testing"
import toml "../.."
import temporal "../../vendor/temporal"

@(test)
test_decoder_adapter_translates_public_parse_results_to_tagged_json :: proc(t: ^testing.T) {
	builder, builder_error := strings.builder_make()
	testing.expect(t, builder_error == nil)
	if builder_error != nil {
		return
	}
	defer strings.builder_destroy(&builder)

	input := "answer = 42\nmessage = \"hello\"\n"
	err := decode_to_writer(
		transmute([]byte)input,
		strings.to_writer(&builder),
	)
	testing.expect(t, err == nil)
	testing.expect_value(
		t,
		strings.to_string(builder),
		`{"answer":{"type":"integer","value":"42"},"message":{"type":"string","value":"hello"}}`,
	)
}

@(test)
test_decoder_adapter_preserves_all_protocol_kinds_exact_keys_and_array_order :: proc(t: ^testing.T) {
	builder, builder_error := strings.builder_make()
	testing.expect(t, builder_error == nil)
	if builder_error != nil {
		return
	}
	defer strings.builder_destroy(&builder)

	input := `"a.b" = [true, 1.5, 1979-05-27T07:32:00Z, 1979-05-27T07:32:00, 1979-05-27, 07:32:00]
[nested]
value = false
`
	err := decode_to_writer(transmute([]byte)input, strings.to_writer(&builder))
	testing.expect(t, err == nil)
	testing.expect_value(
		t,
		strings.to_string(builder),
		`{"a.b":[{"type":"bool","value":"true"},{"type":"float","value":"1.5"},{"type":"datetime","value":"1979-05-27T07:32:00Z"},{"type":"datetime-local","value":"1979-05-27T07:32:00"},{"type":"date-local","value":"1979-05-27"},{"type":"time-local","value":"07:32:00"}],"nested":{"value":{"type":"bool","value":"false"}}}`,
	)
}

@(test)
test_decoder_adapter_rejects_malformed_input_without_protocol_output :: proc(t: ^testing.T) {
	cases := [?]string{
		"key =\n",
		"key = \"\xff\"\n",
	}
	for input in cases {
		builder, builder_error := strings.builder_make()
		testing.expect(t, builder_error == nil)
		if builder_error != nil {
			continue
		}
		err := decode_to_writer(transmute([]byte)input, strings.to_writer(&builder))
		kind, ok := err.(Adapter_Error_Kind)
		testing.expect(t, ok)
		testing.expect_value(t, kind, Adapter_Error_Kind.Malformed_Input)
		testing.expect_value(t, strings.to_string(builder), "")
		strings.builder_destroy(&builder)
	}
}

@(test)
test_decoder_adapter_rejects_unsupported_public_semantic_values_before_output :: proc(t: ^testing.T) {
	doc, parse_error := toml.parse_string("value = 1\n")
	testing.expect(t, parse_error == nil)
	if parse_error != nil {
		return
	}
	defer toml.destroy_document(&doc)
	doc.root[0].value = toml.Value(temporal.Local_Date{year = 2024, month = 13, day = 1})

	builder, builder_error := strings.builder_make()
	testing.expect(t, builder_error == nil)
	if builder_error != nil {
		return
	}
	defer strings.builder_destroy(&builder)

	err := write_document_to_writer(&doc, strings.to_writer(&builder))
	kind, ok := err.(Adapter_Error_Kind)
	testing.expect(t, ok)
	testing.expect_value(t, kind, Adapter_Error_Kind.Unsupported_Protocol_Value)
	testing.expect_value(t, strings.to_string(builder), "")
}

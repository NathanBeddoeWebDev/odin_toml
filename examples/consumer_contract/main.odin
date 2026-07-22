package consumer_contract

import "base:runtime"
import "core:io"
import "core:mem"
import toml "../.."

Buffer_Writer :: struct {
	bytes: [1024]byte,
	count: int,
}

buffer_writer :: proc(state: ^Buffer_Writer) -> io.Writer {
	return {procedure = buffer_writer_proc, data = state}
}

buffer_writer_proc :: proc(
	stream_data: rawptr,
	mode: io.Stream_Mode,
	p: []byte,
	offset: i64,
	whence: io.Seek_From,
) -> (i64, io.Error) {
	_, _ = offset, whence
	state := (^Buffer_Writer)(stream_data)
	assert(mode == .Write)
	assert(state.count+len(p) <= len(state.bytes))
	copy(state.bytes[state.count:], p)
	state.count += len(p)
	return i64(len(p)), nil
}

semantic_ownership_mutation_and_output :: proc() {
	doc, parse_error := toml.parse_string("title = \"before\"\nremove_me = true\n")
	assert(parse_error == nil)
	defer toml.destroy_document(&doc)

	borrowed, found := toml.get(&doc.root, "title")
	assert(found)
	owned, clone_error := toml.clone_value(borrowed)
	assert(clone_error == nil)
	defer toml.destroy_value(&owned, context.allocator)

	// A successful structural mutation invalidates borrowed and every other
	// pointer previously obtained from this table. owned remains independent.
	replacement := toml.Value(toml.String("after"))
	assert(toml.set(&doc.root, "title", &replacement) == nil)
	assert(toml.remove(&doc.root, "remove_me"))
	count := toml.Value(toml.Integer(2))
	assert(toml.set(&doc.root, "count", &count) == nil)
	assert(owned.(toml.String) == "before")

	allocated, unparse_error := toml.unparse(&doc)
	assert(unparse_error == nil)
	defer delete(allocated)
	assert(allocated == "\"title\" = \"after\"\n\"count\" = 2\n")

	writer_state: Buffer_Writer
	options: toml.Marshal_Options
	writer_error := toml.unparse_to_writer(
		buffer_writer(&writer_state), &doc, &options,
	)
	assert(writer_error == nil)
	assert(string(writer_state.bytes[:writer_state.count]) == allocated)
}

Priority :: distinct i64

Config :: struct {
	title:    string,
	priority: Priority,
	enabled:  bool,
}

Codec_State :: struct {
	marshal_calls:   int,
	unmarshal_calls: int,
}

marshal_priority :: proc(
	source: any,
	user_data: rawptr,
	allocator: mem.Allocator,
	loc: runtime.Source_Code_Location,
) -> (toml.Value, toml.Codec_Callback_Error) {
	_, _, _ = allocator, loc, source.id
	state := (^Codec_State)(user_data)
	state.marshal_calls += 1
	return toml.Value(toml.Integer((^Priority)(source.data)^)), nil
}

unmarshal_priority :: proc(
	source: ^toml.Value,
	destination: any,
	user_data: rawptr,
	allocator: mem.Allocator,
	loc: runtime.Source_Code_Location,
) -> toml.Codec_Callback_Error {
	_, _ = allocator, loc
	state := (^Codec_State)(user_data)
	state.unmarshal_calls += 1
	(^Priority)(destination.data)^ = Priority(source^.(toml.Integer))
	return nil
}

cleanup_config :: proc(config: ^Config, allocator := context.allocator) {
	if len(config.title) > 0 {
		assert(delete(config.title, allocator) == nil)
	}
	config^ = {}
}

typed_round_trip_with_codecs :: proc() {
	state: Codec_State
	registry, registry_error := toml.init_codec_registry()
	assert(registry_error == nil)
	defer toml.destroy_codec_registry(&registry)
	assert(toml.register_marshaler(
		&registry,
		typeid_of(Priority),
		{procedure = marshal_priority, user_data = &state},
	) == nil)
	assert(toml.register_unmarshaler(
		&registry,
		typeid_of(Priority),
		{procedure = unmarshal_priority, user_data = &state},
	) == nil)

	source := Config{title = "release", priority = 7, enabled = true}
	encoded, marshal_error := toml.marshal(source, {codecs = &registry})
	assert(marshal_error == nil)
	defer delete(encoded)
	assert(string(encoded) == "\"title\" = \"release\"\n\"priority\" = 7\n\"enabled\" = true\n")

	destination: Config
	unmarshal_error := toml.unmarshal(
		encoded, &destination, {codecs = &registry},
	)
	assert(unmarshal_error == nil)
	defer cleanup_config(&destination)
	assert(destination.title == source.title)
	assert(destination.priority == source.priority)
	assert(destination.enabled == source.enabled)
	assert(state.marshal_calls == 1)
	assert(state.unmarshal_calls == 1)
}

error_results_leave_no_output_owner :: proc() {
	failed_document, parse_error := toml.parse_string("duplicate = 1\nduplicate = 2\n")
	assert(parse_error != nil)
	assert(len(failed_document.root) == 0)
	assert(failed_document.allocator.procedure == nil)

	failed_bytes, marshal_error := toml.marshal(42)
	assert(marshal_error != nil)
	assert(raw_data(failed_bytes) == nil)
}

main :: proc() {
	semantic_ownership_mutation_and_output()
	typed_round_trip_with_codecs()
	error_results_leave_no_output_owner()
}

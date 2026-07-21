package consumer_typed

import "base:runtime"
import "core:io"
import "core:mem"
import toml "../.."

Sample :: struct {
	name: string `toml:"name,omitempty"`,
}

marshal_sample :: proc(
	source: any,
	user_data: rawptr,
	allocator: mem.Allocator,
	loc: runtime.Source_Code_Location,
) -> (toml.Value, toml.Codec_Callback_Error) {
	_, _, _, _ = source, user_data, allocator, loc
	return toml.Value(""), nil
}

unmarshal_sample :: proc(
	source: ^toml.Value,
	destination: any,
	user_data: rawptr,
	allocator: mem.Allocator,
	loc: runtime.Source_Code_Location,
) -> toml.Codec_Callback_Error {
	_, _, _, _, _ = source, destination, user_data, allocator, loc
	return nil
}

main :: proc() {
	parse_success: toml.Parse_Error
	clone_success: toml.Clone_Error
	mutation_success: toml.Mutation_Error
	unparse_success: toml.Unparse_Error
	marshal_success: toml.Marshal_Error
	unmarshal_success: toml.Unmarshal_Error
	registry_success: toml.Codec_Registry_Error
	callback_success: toml.Codec_Callback_Error
	assert(parse_success == nil)
	assert(clone_success == nil)
	assert(mutation_success == nil)
	assert(unparse_success == nil)
	assert(marshal_success == nil)
	assert(unmarshal_success == nil)
	assert(registry_success == nil)
	assert(callback_success == nil)

	if false {
		registry, registry_err := toml.init_codec_registry()
		_ = registry_err
		defer toml.destroy_codec_registry(&registry)
		marshal_err := toml.register_marshaler(
			&registry,
			typeid_of(Sample),
			toml.Codec_Marshaler{procedure = marshal_sample},
		)
		_ = marshal_err
		unmarshal_err := toml.register_unmarshaler(
			&registry,
			typeid_of(Sample),
			toml.Codec_Unmarshaler{procedure = unmarshal_sample},
		)
		_ = unmarshal_err

		options := toml.Marshal_Options{codecs = &registry}
		bytes, err := toml.marshal(Sample{}, options)
		_, _ = bytes, err
		writer_err := toml.marshal_to_writer(io.Writer{}, Sample{}, &options)
		_ = writer_err

		destination: Sample
		decode_err := toml.unmarshal_string("", &destination, {codecs = &registry})
		_ = decode_err
	}
}

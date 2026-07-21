package toml

import "base:runtime"
import "core:mem"

Codec_Callback_Failure :: struct {
	code: u32,
}

Codec_Callback_Error :: union {
	Codec_Callback_Failure,
	runtime.Allocator_Error,
}

Codec_Marshal_Proc :: #type proc(
	source: any,
	user_data: rawptr,
	allocator: mem.Allocator,
	loc: runtime.Source_Code_Location,
) -> (Value, Codec_Callback_Error)

Codec_Unmarshal_Proc :: #type proc(
	source: ^Value,
	destination: any,
	user_data: rawptr,
	allocator: mem.Allocator,
	loc: runtime.Source_Code_Location,
) -> Codec_Callback_Error

Codec_Marshaler :: struct {
	procedure: Codec_Marshal_Proc,
	user_data: rawptr,
}

Codec_Unmarshaler :: struct {
	procedure: Codec_Unmarshal_Proc,
	user_data: rawptr,
}

Codec_Registry :: struct {
	marshalers:   map[typeid]Codec_Marshaler,
	unmarshalers: map[typeid]Codec_Unmarshaler,
	allocator:    mem.Allocator,
	initialized:  bool,
}

@(require_results)
init_codec_registry :: proc(
	allocator := context.allocator,
	loc := #caller_location,
) -> (Codec_Registry, Codec_Registry_Error) {
	_, _ = allocator, loc
	unimplemented("codec registry implementation is scheduled for ticket 10")
}

destroy_codec_registry :: proc(registry: ^Codec_Registry, loc := #caller_location) {
	_, _ = registry, loc
	unimplemented("codec registry implementation is scheduled for ticket 10")
}

@(require_results)
register_marshaler :: proc(
	registry: ^Codec_Registry,
	id: typeid,
	marshaler: Codec_Marshaler,
	loc := #caller_location,
) -> Codec_Registry_Error {
	_, _, _, _ = registry, id, marshaler, loc
	unimplemented("codec registry implementation is scheduled for ticket 10")
}

@(require_results)
register_unmarshaler :: proc(
	registry: ^Codec_Registry,
	id: typeid,
	unmarshaler: Codec_Unmarshaler,
	loc := #caller_location,
) -> Codec_Registry_Error {
	_, _, _, _ = registry, id, unmarshaler, loc
	unimplemented("codec registry implementation is scheduled for ticket 10")
}

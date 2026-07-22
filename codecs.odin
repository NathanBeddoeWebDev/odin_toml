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
	_ = loc
	if allocator.procedure == nil {
		return {}, Codec_Registry_Data_Error.Invalid_Allocator
	}
	return Codec_Registry{
		marshalers = make(map[typeid]Codec_Marshaler, allocator),
		unmarshalers = make(map[typeid]Codec_Unmarshaler, allocator),
		allocator = allocator,
		initialized = true,
	}, nil
}

@(private)
release_codec_map_storage :: proc(
	gate: ^Allocator_Release_Gate,
	mapping: $M/map[$K]$V,
	loc: runtime.Source_Code_Location,
) {
	if cap(mapping) == 0 {
		return
	}
	raw_map := transmute(runtime.Raw_Map)mapping
	err := allocator_release_gate_release(
		gate,
		rawptr(runtime.map_data(raw_map)),
		int(runtime.map_total_allocation_size_from_value(mapping)),
		loc,
	)
	assert(err == nil, "codec registry allocator violated its destruction contract")
}

destroy_codec_registry :: proc(registry: ^Codec_Registry, loc := #caller_location) {
	if registry == nil || !registry.initialized {
		return
	}
	owner := registry^
	registry^ = {}
	gate, gate_error := allocator_release_gate_init(owner.allocator, loc)
	assert(gate_error == nil, "codec registry allocator rejected destruction setup")
	release_codec_map_storage(&gate, owner.marshalers, loc)
	release_codec_map_storage(&gate, owner.unmarshalers, loc)
	owner = {}
}

@(private)
codec_registry_is_valid :: proc(registry: ^Codec_Registry) -> bool {
	return registry != nil && registry.initialized &&
	       registry.allocator.procedure != nil &&
	       allocator_equal(registry.marshalers.allocator, registry.allocator) &&
	       allocator_equal(registry.unmarshalers.allocator, registry.allocator)
}

@(private)
validate_codec_registration :: proc(
	registry: ^Codec_Registry,
	id: typeid,
	has_callback: bool,
) -> Codec_Registry_Error {
	if !codec_registry_is_valid(registry) {
		return Codec_Registry_Data_Error.Invalid_Registry
	}
	zero_id: typeid
	if id == zero_id {
		return Codec_Registry_Data_Error.Invalid_Type_ID
	}
	if !has_callback {
		return Codec_Registry_Data_Error.Nil_Callback
	}
	return nil
}

@(private)
register_directional_codec :: proc(
	mapping: ^$M/map[typeid]$V,
	id: typeid,
	codec: V,
	loc: runtime.Source_Code_Location,
) -> Codec_Registry_Error {
	if id in mapping^ {
		return Codec_Registry_Data_Error.Duplicate_Codec
	}
	key := id
	value := codec
	_, err := runtime.__dynamic_map_set_without_hash(
		(^runtime.Raw_Map)(mapping),
		runtime.map_info(M),
		rawptr(&key),
		rawptr(&value),
		loc,
	)
	if err != nil {
		return err
	}
	return nil
}

@(require_results)
register_marshaler :: proc(
	registry: ^Codec_Registry,
	id: typeid,
	marshaler: Codec_Marshaler,
	loc := #caller_location,
) -> Codec_Registry_Error {
	if err := validate_codec_registration(
		registry,
		id,
		marshaler.procedure != nil,
	); err != nil {
		return err
	}
	return register_directional_codec(&registry.marshalers, id, marshaler, loc)
}

@(require_results)
register_unmarshaler :: proc(
	registry: ^Codec_Registry,
	id: typeid,
	unmarshaler: Codec_Unmarshaler,
	loc := #caller_location,
) -> Codec_Registry_Error {
	if err := validate_codec_registration(
		registry,
		id,
		unmarshaler.procedure != nil,
	); err != nil {
		return err
	}
	return register_directional_codec(&registry.unmarshalers, id, unmarshaler, loc)
}

@(private)
marshal_codec_value :: proc(
	builder: ^Marshal_Builder,
	source: any,
) -> (Value, Marshal_Error, bool) {
	if builder.codecs == nil {
		return {}, nil, false
	}
	marshaler, found := builder.codecs.marshalers[source.id]
	if !found {
		return {}, nil, false
	}
	value, callback_error := marshaler.procedure(
		source,
		marshaler.user_data,
		builder.allocator,
		builder.loc,
	)
	if callback_error == nil {
		cached, cache_error := marshal_codec_cache_value(builder, source, value)
		return cached, cache_error, true
	}
	if allocator_error, ok := callback_error.(runtime.Allocator_Error); ok {
		return {}, allocator_error, true
	}
	failure := callback_error.(Codec_Callback_Failure)
	assert(failure.code != 0, "codec callback failure codes must be nonzero")
	return {}, Marshal_Diagnostic{
		detail = Marshal_Codec_Error{
			registered_type = source.id,
			code = failure.code,
		},
		path = marshal_path_snapshot(builder),
	}, true
}

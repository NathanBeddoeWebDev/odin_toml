package toml

import "base:runtime"
import "core:mem"
import "core:reflect"

@(private)
Marshal_Codec_Region :: struct {
	start:     uintptr,
	size:      int,
	allocator: mem.Allocator,
}

@(private)
Marshal_Codec_Owner :: struct {
	value:   Value,
	regions: [dynamic]Marshal_Codec_Region,
}

@(private)
marshal_codec_regions_overlap :: proc(a, b: Marshal_Codec_Region) -> bool {
	return regions_overlap(a.start, a.size, b.start, b.size)
}

@(private)
marshal_codec_region_seen_before :: proc(
	owners: []Marshal_Codec_Owner,
	owner_index, region_index: int,
	region: Marshal_Codec_Region,
) -> bool {
	for previous_owner_index in 0..=owner_index {
		region_limit := len(owners[previous_owner_index].regions)
		if previous_owner_index == owner_index {
			region_limit = region_index
		}
		for previous in owners[previous_owner_index].regions[:region_limit] {
			if marshal_codec_regions_overlap(region, previous) {
				return true
			}
		}
	}
	return false
}

@(private)
marshal_codec_release_region :: proc(
	region: Marshal_Codec_Region,
	loc: runtime.Source_Code_Location,
) {
	if region.size == 0 || region.allocator.procedure == nil {
		return
	}
	gate, gate_error := allocator_release_gate_init(region.allocator, loc)
	assert(gate_error == nil, "codec value allocator rejected destruction setup")
	release_owned_memory(&gate, rawptr(region.start), region.size, loc)
}

@(private)
marshal_codec_owners_destroy :: proc(
	owners: ^[dynamic]Marshal_Codec_Owner,
	allocator: mem.Allocator,
	loc: runtime.Source_Code_Location,
) {
	if owners == nil {
		return
	}
	for &owner, owner_index in owners {
		for region_index := len(owner.regions)-1; region_index >= 0; region_index -= 1 {
			region := owner.regions[region_index]
			if !marshal_codec_region_seen_before(
				owners[:],
				owner_index,
				region_index,
				region,
			) {
				marshal_codec_release_region(region, loc)
			}
		}
		owner.value = {}
	}
	gate, gate_error := allocator_release_gate_init(allocator, loc)
	assert(gate_error == nil, "codec cache allocator rejected destruction setup")
	for &owner in owners {
		release_owned_memory(
			&gate,
			raw_data(owner.regions),
			cap(owner.regions)*size_of(Marshal_Codec_Region),
			loc,
		)
		owner.regions = nil
	}
	release_owned_memory(
		&gate,
		raw_data(owners^),
		cap(owners^)*size_of(Marshal_Codec_Owner),
		loc,
	)
	owners^ = nil
}

@(private)
marshal_codec_owners_grow :: proc(builder: ^Marshal_Builder) -> Marshal_Error {
	old_capacity := cap(builder.codec_owners)
	new_capacity := 4
	if old_capacity > 0 {
		if old_capacity > max(int)/2 {
			return marshal_limit_error(builder, .Size_Overflow)
		}
		new_capacity = old_capacity*2
	}
	raw, storage_error := make_owned_dynamic_array_storage(
		new_capacity,
		size_of(Marshal_Codec_Owner),
		builder.allocator,
		builder.loc,
	)
	if storage_error != nil {
		if allocator_error, ok := storage_error.(runtime.Allocator_Error); ok {
			return allocator_error
		}
		return marshal_limit_error(builder, .Size_Overflow)
	}
	old_count := len(builder.codec_owners)
	grown := transmute([dynamic]Marshal_Codec_Owner)raw
	if old_count > 0 {
		mem.copy_non_overlapping(
			raw_data(grown),
			raw_data(builder.codec_owners),
			old_count*size_of(Marshal_Codec_Owner),
		)
	}
	release_owned_memory(
		&builder.gate,
		raw_data(builder.codec_owners),
		old_capacity*size_of(Marshal_Codec_Owner),
		builder.loc,
	)
	descriptor := transmute(runtime.Raw_Dynamic_Array)grown
	descriptor.len = old_count
	builder.codec_owners = transmute([dynamic]Marshal_Codec_Owner)descriptor
	return nil
}

@(private)
marshal_codec_regions_grow :: proc(
	builder: ^Marshal_Builder,
	regions: ^[dynamic]Marshal_Codec_Region,
) -> Marshal_Error {
	old_capacity := cap(regions^)
	new_capacity := 8
	if old_capacity > 0 {
		if old_capacity > max(int)/2 {
			return marshal_limit_error(builder, .Size_Overflow)
		}
		new_capacity = old_capacity*2
	}
	raw, storage_error := make_owned_dynamic_array_storage(
		new_capacity,
		size_of(Marshal_Codec_Region),
		builder.allocator,
		builder.loc,
	)
	if storage_error != nil {
		if allocator_error, ok := storage_error.(runtime.Allocator_Error); ok {
			return allocator_error
		}
		return marshal_limit_error(builder, .Size_Overflow)
	}
	old_count := len(regions^)
	grown := transmute([dynamic]Marshal_Codec_Region)raw
	if old_count > 0 {
		mem.copy_non_overlapping(
			raw_data(grown),
			raw_data(regions^),
			old_count*size_of(Marshal_Codec_Region),
		)
	}
	release_owned_memory(
		&builder.gate,
		raw_data(regions^),
		old_capacity*size_of(Marshal_Codec_Region),
		builder.loc,
	)
	descriptor := transmute(runtime.Raw_Dynamic_Array)grown
	descriptor.len = old_count
	regions^ = transmute([dynamic]Marshal_Codec_Region)descriptor
	return nil
}

@(private)
marshal_codec_collect_region :: proc(
	builder: ^Marshal_Builder,
	regions: ^[dynamic]Marshal_Codec_Region,
	region: Marshal_Codec_Region,
) -> (seen: bool, err: Marshal_Error) {
	if region.size == 0 {
		return false, nil
	}
	for existing in regions {
		if marshal_codec_regions_overlap(region, existing) {
			return true, nil
		}
	}
	if len(regions^) == cap(regions^) {
		if grow_error := marshal_codec_regions_grow(builder, regions); grow_error != nil {
			return false, grow_error
		}
	}
	append(regions, region)
	return false, nil
}

@(private)
marshal_codec_collect_value_regions :: proc(
	builder: ^Marshal_Builder,
	value: ^Value,
	inherited_allocator: mem.Allocator,
	regions: ^[dynamic]Marshal_Codec_Region,
) -> Marshal_Error {
	if value == nil {
		return nil
	}
	tag := reflect.get_union_variant_raw_tag(value^)
	if tag < 0 || tag >= 10 {
		return nil
	}
	#partial switch item in value^ {
	case String:
		if len(item) > 0 && raw_data(item) != nil {
			_, err := marshal_codec_collect_region(
				builder,
				regions,
				{uintptr(raw_data(item)), len(item), inherited_allocator},
			)
			return err
		}
	case Array:
		raw := transmute(runtime.Raw_Dynamic_Array)item
		valid_shape := raw.len >= 0 && raw.cap >= raw.len && raw.cap >= 0 &&
		               raw.cap <= max(int)/size_of(Value) &&
		               (raw.cap == 0 || raw.data != nil)
		if !valid_shape {
			return nil
		}
		seen, region_error := marshal_codec_collect_region(
			builder,
			regions,
			{uintptr(raw.data), raw.cap*size_of(Value), raw.allocator},
		)
		if region_error != nil || seen {
			return region_error
		}
		for &child in item {
			if err := marshal_codec_collect_value_regions(
				builder,
				&child,
				raw.allocator,
				regions,
			); err != nil {
				return err
			}
		}
	case Table:
		raw := transmute(runtime.Raw_Dynamic_Array)item
		valid_shape := raw.len >= 0 && raw.cap >= raw.len && raw.cap >= 0 &&
		               raw.cap <= max(int)/size_of(Entry) &&
		               (raw.cap == 0 || raw.data != nil)
		if !valid_shape {
			return nil
		}
		seen, region_error := marshal_codec_collect_region(
			builder,
			regions,
			{uintptr(raw.data), raw.cap*size_of(Entry), raw.allocator},
		)
		if region_error != nil || seen {
			return region_error
		}
		for &entry in item {
			if len(entry.key) > 0 && raw_data(entry.key) != nil {
				_, key_error := marshal_codec_collect_region(
					builder,
					regions,
					{uintptr(raw_data(entry.key)), len(entry.key), raw.allocator},
				)
				if key_error != nil {
					return key_error
				}
			}
			if value_error := marshal_codec_collect_value_regions(
				builder,
				&entry.value,
				raw.allocator,
				regions,
			); value_error != nil {
				return value_error
			}
		}
	}
	return nil
}

@(private)
marshal_codec_release_untracked_owner :: proc(
	builder: ^Marshal_Builder,
	value: ^Value,
	regions: ^[dynamic]Marshal_Codec_Region,
) {
	for region_index := len(regions^)-1; region_index >= 0; region_index -= 1 {
		region := regions[region_index]
		seen := false
		for owner in builder.codec_owners {
			for existing in owner.regions {
				if marshal_codec_regions_overlap(region, existing) {
					seen = true
					break
				}
			}
			if seen {
				break
			}
		}
		if !seen {
			marshal_codec_release_region(region, builder.loc)
		}
	}
	value^ = {}
	release_owned_memory(
		&builder.gate,
		raw_data(regions^),
		cap(regions^)*size_of(Marshal_Codec_Region),
		builder.loc,
	)
	regions^ = nil
}

@(private)
marshal_codec_append_owner :: proc(
	builder: ^Marshal_Builder,
	value: Value,
	regions: [dynamic]Marshal_Codec_Region,
) -> Marshal_Error {
	if len(builder.codec_owners) == cap(builder.codec_owners) {
		if grow_error := marshal_codec_owners_grow(builder); grow_error != nil {
			return grow_error
		}
	}
	append(&builder.codec_owners, Marshal_Codec_Owner{
		value = value,
		regions = regions,
	})
	return nil
}

@(private)
marshal_codec_validation_error :: proc(
	builder: ^Marshal_Builder,
	err: Semantic_Validation_Error,
	registered_type: typeid,
) -> Marshal_Error {
	if allocator_error, ok := err.(runtime.Allocator_Error); ok {
		return allocator_error
	}
	diagnostic := err.(Semantic_Diagnostic)
	if limit, ok := diagnostic.detail.(Mutation_Limit_Error); ok {
		return marshal_limit_error(builder, Marshal_Limit_Error(limit))
	}
	semantic_kind := diagnostic.detail.(Semantic_Data_Error)
	kind: Marshal_Data_Error_Kind
	switch semantic_kind {
	case .Invalid_Document, .Invalid_Table, .Invalid_Value_State:
		kind = .Invalid_Value_State
	case .Invalid_Container, .Uninitialized_Container:
		kind = .Invalid_Container
	case .Invalid_Key_Text, .Invalid_Value_Text:
		kind = .Invalid_Text
	case .Duplicate_Key:
		kind = .Duplicate_Key
	case .Invalid_Temporal:
		kind = .Invalid_Temporal
	case .Cycle:
		kind = .Codec_Value_Cycle
	case .Ownership_Alias:
		kind = .Codec_Value_Ownership_Alias
	case .Allocator_Mismatch:
		kind = .Codec_Value_Allocator_Mismatch
	}
	zero_type: typeid
	// Callback-owned strings cease to exist before this error returns, so the
	// frozen allocation-free diagnostic can safely retain only the source path.
	return marshal_data_error_detail(
		builder,
		kind,
		registered_type,
		zero_type,
		diagnostic.temporal_error,
		0,
		0,
	)
}

@(private)
marshal_codec_values_overlap :: proc(
	owners: []Marshal_Codec_Owner,
	regions: []Marshal_Codec_Region,
) -> bool {
	for owner in owners {
		for existing in owner.regions {
			for current in regions {
				if marshal_codec_regions_overlap(existing, current) {
					return true
				}
			}
		}
	}
	return false
}

@(private)
marshal_codec_cache_value :: proc(
	builder: ^Marshal_Builder,
	source: any,
	value: Value,
) -> (Value, Marshal_Error) {
	owned := value
	regions: [dynamic]Marshal_Codec_Region
	if collect_error := marshal_codec_collect_value_regions(
		builder,
		&owned,
		builder.allocator,
		&regions,
	); collect_error != nil {
		// A successful callback promises a structurally complete owner. That
		// contract makes ordinary destruction safe when cleanup-ledger scratch
		// itself cannot be allocated.
		destroy_value(&owned, builder.allocator, builder.loc)
		return {}, collect_error
	}
	validation, init_error := semantic_validation_state_init(
		builder.allocator,
		builder.allocator,
		true,
		builder.loc,
		max_depth = builder.max_depth,
	)
	if init_error != nil {
		marshal_codec_release_untracked_owner(builder, &owned, &regions)
		return {}, init_error
	}
	validation.path_count = builder.path_count
	copy(validation.path[:builder.path_count], builder.path[:builder.path_count])
	validation_error := semantic_validate_value(&validation, &owned, builder.loc)
	if validation_error != nil {
		mapped := marshal_codec_validation_error(builder, validation_error, source.id)
		semantic_validation_state_destroy(&validation, builder.loc)
		if append_error := marshal_codec_append_owner(builder, owned, regions); append_error != nil {
			marshal_codec_release_untracked_owner(builder, &owned, &regions)
			return {}, append_error
		}
		return {}, mapped
	}
	semantic_validation_state_destroy(&validation, builder.loc)

	if marshal_codec_values_overlap(builder.codec_owners[:], regions[:]) {
		error := marshal_data_error(builder, .Codec_Value_Ownership_Alias, source.id)
		if append_error := marshal_codec_append_owner(builder, owned, regions); append_error != nil {
			marshal_codec_release_untracked_owner(builder, &owned, &regions)
			return {}, append_error
		}
		return {}, error
	}

	cloned, clone_error := clone_value_with_gate(
		&owned,
		builder.allocator,
		&builder.gate,
		builder.loc,
	)
	if clone_error != nil {
		if append_error := marshal_codec_append_owner(builder, owned, regions); append_error != nil {
			marshal_codec_release_untracked_owner(builder, &owned, &regions)
			return {}, append_error
		}
		if allocator_error, ok := clone_error.(runtime.Allocator_Error); ok {
			return {}, allocator_error
		}
		return {}, marshal_limit_error(builder, .Size_Overflow)
	}
	if append_error := marshal_codec_append_owner(builder, owned, regions); append_error != nil {
		destroy_value_with_gate(&cloned, &builder.gate, builder.loc)
		marshal_codec_release_untracked_owner(builder, &owned, &regions)
		return {}, append_error
	}
	return cloned, nil
}

package toml

import "base:runtime"
import "core:io"
import "core:mem"
import "core:unicode/utf8"
import temporal "temporal"

@(private)
Marshal_Builder :: struct {
	allocator: mem.Allocator,
	gate:      Allocator_Release_Gate,
	loc:       runtime.Source_Code_Location,
	path:      [SEMANTIC_MAX_DEPTH + 1]Encode_Diagnostic_Path_Segment,
	path_count: int,
	max_depth:  int,
	active_references: [dynamic]Marshal_Active_Reference,
}

@(private)
Typed_Marshal_Plan :: struct {
	document:  Document,
	canonical: Canonical_Encoding_Plan,
	initialized: bool,
}

@(private)
marshal_configuration_error :: proc(kind: Marshal_Configuration_Error) -> Marshal_Error {
	return kind
}

@(private)
marshal_path_snapshot :: proc(builder: ^Marshal_Builder) -> Encode_Diagnostic_Path {
	result: Encode_Diagnostic_Path
	count := builder.path_count
	result.total_segment_count = u16(count)
	if count <= len(result.segments) {
		result.segment_count = u8(count)
		result.prefix_count = u8(count)
		copy(result.segments[:count], builder.path[:count])
		return result
	}
	prefix_count := 8
	suffix_count := len(result.segments)-prefix_count
	result.segment_count = u8(len(result.segments))
	result.prefix_count = u8(prefix_count)
	result.omitted_segment_count = u16(count-len(result.segments))
	result.truncated = true
	copy(result.segments[:prefix_count], builder.path[:prefix_count])
	copy(result.segments[prefix_count:], builder.path[count-suffix_count:count])
	return result
}

@(private)
marshal_data_error_detail :: proc(
	builder: ^Marshal_Builder,
	kind: Marshal_Data_Error_Kind,
	source_type: typeid,
	related_type: typeid,
	temporal_error: temporal.Error,
	expected_count, actual_count: int,
) -> Marshal_Error {
	return Marshal_Diagnostic{
		detail = Marshal_Data_Error{
			kind = kind,
			source_type = source_type,
			related_type = related_type,
			temporal_error = temporal_error,
			expected_count = expected_count,
			actual_count = actual_count,
		},
		path = marshal_path_snapshot(builder),
	}
}

@(private)
marshal_data_error :: proc(
	builder: ^Marshal_Builder,
	kind: Marshal_Data_Error_Kind,
	source_type: typeid,
) -> Marshal_Error {
	zero_type: typeid
	return marshal_data_error_detail(
		builder,
		kind,
		source_type,
		zero_type,
		.None,
		0,
		0,
	)
}

@(private)
marshal_limit_error :: proc(
	builder: ^Marshal_Builder,
	kind: Marshal_Limit_Error,
) -> Marshal_Error {
	return Marshal_Diagnostic{
		detail = Marshal_Diagnostic_Detail(kind),
		path = marshal_path_snapshot(builder),
	}
}

@(private)
marshal_push_path :: proc(
	builder: ^Marshal_Builder,
	segment: Encode_Diagnostic_Path_Segment,
) -> Marshal_Error {
	if builder.path_count >= builder.max_depth {
		builder.path[builder.path_count] = segment
		builder.path_count += 1
		err := marshal_limit_error(builder, .Maximum_Depth_Exceeded)
		builder.path_count -= 1
		builder.path[builder.path_count] = {}
		return err
	}
	builder.path[builder.path_count] = segment
	builder.path_count += 1
	return nil
}

@(private)
marshal_pop_path :: proc(builder: ^Marshal_Builder) {
	assert(builder.path_count > 0)
	builder.path_count -= 1
	builder.path[builder.path_count] = {}
}

@(private)
marshal_clone_text :: proc(
	builder: ^Marshal_Builder,
	text: string,
	source_type: typeid,
) -> (string, Marshal_Error) {
	if !utf8.valid_string(text) {
		return "", marshal_data_error(builder, .Invalid_Text, source_type)
	}
	cloned, err := clone_owned_string(text, builder.allocator, builder.loc)
	if err != nil {
		if allocator_error, ok := err.(runtime.Allocator_Error); ok {
			return "", allocator_error
		}
		return "", marshal_limit_error(builder, .Size_Overflow)
	}
	return cloned, nil
}

@(private)
marshal_rebase_path :: proc(
	path: Encode_Diagnostic_Path,
	source: any,
) -> Encode_Diagnostic_Path {
	result := path
	current := source
	parser := Marshal_Builder{max_depth = SEMANTIC_MAX_DEPTH}
	prefix_count := int(result.segment_count)
	if result.truncated {
		prefix_count = int(result.prefix_count)
	}
	for index in 0..<prefix_count {
		temporary_name, is_name := result.segments[index].(string)
		if !is_name || current == nil {
			return result
		}
		stable_name, field_value, matched := marshal_projected_field_value_by_name(
			&parser,
			current,
			temporary_name,
		)
		if !matched {
			return result
		}
		result.segments[index] = stable_name
		current = field_value
	}
	if result.truncated {
		suffix := result.segments[prefix_count:int(result.segment_count)]
		stable: [32]Encode_Diagnostic_Path_Segment
		if marshal_rebase_projected_suffix(
			&parser,
			current,
			int(result.omitted_segment_count),
			suffix,
			stable[:len(suffix)],
		) {
			copy(suffix, stable[:len(suffix)])
		}
	}
	return result
}

@(private)
marshal_unparse_error :: proc(err: Unparse_Error, source: any) -> Marshal_Error {
	if err == nil {
		return nil
	}
	if configuration, ok := err.(Unparse_Configuration_Error); ok {
		switch configuration {
		case .Invalid_Allocator: return Marshal_Configuration_Error.Invalid_Allocator
		case .Invalid_Max_Depth: return Marshal_Configuration_Error.Invalid_Max_Depth
		case .Nil_Options:       return Marshal_Configuration_Error.Nil_Options
		}
	}
	if allocator_error, ok := err.(runtime.Allocator_Error); ok {
		return allocator_error
	}
	if writer_error, ok := err.(io.Error); ok {
		return writer_error
	}
	diagnostic := err.(Unparse_Diagnostic)
	diagnostic.path = marshal_rebase_path(diagnostic.path, source)
	if limit, ok := diagnostic.detail.(Unparse_Limit_Error); ok {
		return Marshal_Diagnostic{detail = Marshal_Limit_Error(limit), path = diagnostic.path}
	}
	kind := diagnostic.detail.(Unparse_Data_Error_Kind)
	marshal_kind: Marshal_Data_Error_Kind
	switch kind {
	case .Invalid_Document:    marshal_kind = .Invalid_Value_State
	case .Invalid_Value_State: marshal_kind = .Invalid_Value_State
	case .Invalid_Container:   marshal_kind = .Invalid_Container
	case .Invalid_Text:        marshal_kind = .Invalid_Text
	case .Duplicate_Key:       marshal_kind = .Duplicate_Key
	case .Invalid_Temporal:    marshal_kind = .Invalid_Temporal
	case .Cycle:               marshal_kind = .Active_Recursion_Cycle
	case .Ownership_Alias:     marshal_kind = .Invalid_Value_State
	case .Allocator_Mismatch:  marshal_kind = .Invalid_Value_State
	}
	return Marshal_Diagnostic{
		detail = Marshal_Data_Error{kind = marshal_kind, temporal_error = diagnostic.temporal_error},
		path = diagnostic.path,
	}
}

@(private)
marshal_configuration :: proc(
	options: ^Marshal_Options,
	allocator: mem.Allocator,
	writer_form: bool,
) -> (int, Marshal_Error) {
	if allocator.procedure == nil {
		return 0, marshal_configuration_error(.Invalid_Allocator)
	}
	if writer_form && options == nil {
		return 0, marshal_configuration_error(.Nil_Options)
	}
	max_depth := options.max_depth
	if max_depth == 0 {
		max_depth = 128
	} else if max_depth < 1 || max_depth > SEMANTIC_MAX_DEPTH {
		return 0, marshal_configuration_error(.Invalid_Max_Depth)
	}
	return max_depth, nil
}

@(private)
marshal_document_build :: proc(
	value: any,
	max_depth: int,
	allocator: mem.Allocator,
	loc: runtime.Source_Code_Location,
) -> (Document, Marshal_Error) {
	builder := Marshal_Builder{
		allocator = allocator,
		loc = loc,
		max_depth = max_depth,
	}
	if value == nil {
		zero_type: typeid
		return {}, marshal_data_error(&builder, .Unsupported_Nil, zero_type)
	}
	gate_error: runtime.Allocator_Error
	builder.gate, gate_error = allocator_release_gate_init(allocator, loc)
	if gate_error != nil {
		return {}, gate_error
	}
	defer marshal_active_references_destroy(&builder)
	root, root_error := marshal_root_table(&builder, value)
	if root_error != nil {
		return {}, root_error
	}
	return Document{root = root, allocator = allocator}, nil
}

@(private)
typed_marshal_plan_destroy :: proc(
	plan: ^Typed_Marshal_Plan,
	loc: runtime.Source_Code_Location,
) {
	if plan == nil || !plan.initialized {
		return
	}
	canonical_encoding_plan_destroy(&plan.canonical, loc)
	destroy_document(&plan.document, loc)
	plan^ = {}
}

@(private)
typed_marshal_plan_build :: proc(
	value: any,
	max_depth: int,
	allocator: mem.Allocator,
	loc: runtime.Source_Code_Location,
) -> (plan: Typed_Marshal_Plan, err: Marshal_Error) {
	plan.document, err = marshal_document_build(value, max_depth, allocator, loc)
	if err != nil {
		return {}, err
	}
	plan.initialized = true
	canonical_error: Unparse_Error
	plan.canonical, canonical_error = canonical_encoding_plan_build(
		&plan.document,
		max_depth,
		allocator,
		loc,
	)
	if canonical_error != nil {
		err = marshal_unparse_error(canonical_error, value)
		typed_marshal_plan_destroy(&plan, loc)
		return {}, err
	}
	return
}

@(require_results)
marshal :: proc(
	value: any,
	options: Marshal_Options = {},
	allocator := context.allocator,
	loc := #caller_location,
) -> ([]byte, Marshal_Error) {
	options_copy := options
	max_depth, configuration_error := marshal_configuration(&options_copy, allocator, false)
	if configuration_error != nil {
		return nil, configuration_error
	}
	plan, plan_error := typed_marshal_plan_build(value, max_depth, allocator, loc)
	if plan_error != nil {
		return nil, plan_error
	}
	defer typed_marshal_plan_destroy(&plan, loc)
	encoded, emission_error := canonical_encoding_plan_emit_allocated(
		&plan.canonical,
		plan.document.root,
		allocator,
		loc,
	)
	if emission_error != nil {
		return nil, marshal_unparse_error(emission_error, value)
	}
	return transmute([]byte)encoded, nil
}

@(require_results)
marshal_to_writer :: proc(
	writer: io.Writer,
	value: any,
	options: ^Marshal_Options,
	allocator := context.allocator,
	loc := #caller_location,
) -> Marshal_Error {
	max_depth, configuration_error := marshal_configuration(options, allocator, true)
	if configuration_error != nil {
		return configuration_error
	}
	plan, plan_error := typed_marshal_plan_build(value, max_depth, allocator, loc)
	if plan_error != nil {
		return plan_error
	}
	defer typed_marshal_plan_destroy(&plan, loc)
	return marshal_unparse_error(
		canonical_encoding_plan_emit_writer(&plan.canonical, plan.document.root, writer),
		value,
	)
}

package toml

import "base:runtime"
import "core:io"
import "core:mem"
import temporal "external:temporal"

@(private)
Canonical_Encoder_Mode :: enum u8 {
	Sizing,
	Output,
	Writer,
}

@(private)
Canonical_Encoder :: struct {
	mode:         Canonical_Encoder_Mode,
	output:       []byte,
	writer:       io.Writer,
	count:        int,
	writer_error: io.Error,
}

@(private)
Canonical_Encoding_Plan :: struct {
	validation:   Semantic_Validation_State,
	encoded_size: int,
	initialized:  bool,
}

@(private)
unparse_configuration_error :: proc(kind: Unparse_Configuration_Error) -> Unparse_Error {
	return kind
}

@(private)
unparse_validation_error :: proc(err: Semantic_Validation_Error) -> Unparse_Error {
	if err == nil {
		return nil
	}
	if allocator_error, ok := err.(runtime.Allocator_Error); ok {
		return allocator_error
	}
	diagnostic := err.(Semantic_Diagnostic)
	if limit, ok := diagnostic.detail.(Mutation_Limit_Error); ok {
		return Unparse_Diagnostic{
			detail = Unparse_Diagnostic_Detail(Unparse_Limit_Error(limit)),
			temporal_error = diagnostic.temporal_error,
			path = diagnostic.path,
		}
	}

	kind := diagnostic.detail.(Semantic_Data_Error)
	unparse_kind: Unparse_Data_Error_Kind
	switch kind {
	case .Invalid_Document, .Invalid_Table:
		unparse_kind = .Invalid_Document
	case .Invalid_Value_State:
		unparse_kind = .Invalid_Value_State
	case .Invalid_Container, .Uninitialized_Container:
		unparse_kind = .Invalid_Container
	case .Invalid_Key_Text, .Invalid_Value_Text:
		unparse_kind = .Invalid_Text
	case .Duplicate_Key:
		unparse_kind = .Duplicate_Key
	case .Invalid_Temporal:
		unparse_kind = .Invalid_Temporal
	case .Cycle:
		unparse_kind = .Cycle
	case .Ownership_Alias:
		unparse_kind = .Ownership_Alias
	case .Allocator_Mismatch:
		unparse_kind = .Allocator_Mismatch
	}
	return Unparse_Diagnostic{
		detail = Unparse_Diagnostic_Detail(unparse_kind),
		temporal_error = diagnostic.temporal_error,
		path = diagnostic.path,
	}
}

@(private)
canonical_append_bytes :: proc(
	encoder: ^Canonical_Encoder,
	bytes: []byte,
	state: ^Semantic_Validation_State,
) -> Semantic_Validation_Error {
	if encoder.mode == .Writer && encoder.writer_error != nil {
		return nil
	}
	if len(bytes) > max(int)-encoder.count {
		return semantic_diagnostic(state, Mutation_Limit_Error.Size_Overflow)
	}
	next := encoder.count+len(bytes)
	switch encoder.mode {
	case .Sizing:
		encoder.count = next
	case .Output:
		assert(next <= len(encoder.output))
		copy(encoder.output[encoder.count:next], bytes)
		encoder.count = next
	case .Writer:
		written, writer_error := io.write(encoder.writer, bytes)
		if writer_error != nil {
			if 0 <= written && written <= len(bytes) {
				encoder.count += written
			}
			encoder.writer_error = writer_error
			return nil
		}
		if written < 0 || written > len(bytes) {
			encoder.writer_error = .Invalid_Write
			return nil
		}
		encoder.count += written
		if written < len(bytes) {
			encoder.writer_error = .Short_Write
		}
	}
	return nil
}

@(private)
canonical_append_text :: proc(
	encoder: ^Canonical_Encoder,
	text: string,
	state: ^Semantic_Validation_State,
) -> Semantic_Validation_Error {
	return canonical_append_bytes(encoder, transmute([]byte)text, state)
}

@(private)
canonical_append_byte :: proc(
	encoder: ^Canonical_Encoder,
	value: byte,
	state: ^Semantic_Validation_State,
) -> Semantic_Validation_Error {
	bytes := []byte{value}
	return canonical_append_bytes(encoder, bytes, state)
}

@(private)
canonical_encode_quoted_text :: proc(
	encoder: ^Canonical_Encoder,
	text: string,
	state: ^Semantic_Validation_State,
) -> Semantic_Validation_Error {
	if err := canonical_append_text(encoder, `"`, state); err != nil {
		return err
	}
	start := 0
	for index in 0..<len(text) {
		character := text[index]
		escape: string
		switch character {
		case '"': escape = `\"`
		case '\\': escape = `\\`
		case '\b': escape = `\b`
		case '\t': escape = `\t`
		case '\n': escape = `\n`
		case '\f': escape = `\f`
		case '\r': escape = `\r`
		case 0x1b: escape = `\e`
		case:
			if character < 0x20 || character == 0x7f {
				hex := "0123456789ABCDEF"
				encoded := [4]byte{'\\', 'x', hex[character>>4], hex[character&0x0f]}
				if start < index {
					if err := canonical_append_text(encoder, text[start:index], state); err != nil {
						return err
					}
				}
				if err := canonical_append_bytes(encoder, encoded[:], state); err != nil {
					return err
				}
				start = index+1
			}
			continue
		}
		if start < index {
			if err := canonical_append_text(encoder, text[start:index], state); err != nil {
				return err
			}
		}
		if err := canonical_append_text(encoder, escape, state); err != nil {
			return err
		}
		start = index+1
	}
	if start < len(text) {
		if err := canonical_append_text(encoder, text[start:], state); err != nil {
			return err
		}
	}
	return canonical_append_text(encoder, `"`, state)
}

@(private)
canonical_encode_integer :: proc(
	encoder: ^Canonical_Encoder,
	value: Integer,
	state: ^Semantic_Validation_State,
) -> Semantic_Validation_Error {
	negative := value < 0
	magnitude := u64(value)
	if negative {
		magnitude = 0-magnitude
	}
	reversed: [20]byte
	count := 0
	for {
		reversed[count] = byte(magnitude%10)+'0'
		count += 1
		magnitude /= 10
		if magnitude == 0 {
			break
		}
	}
	buffer: [21]byte
	index := 0
	if negative {
		buffer[index] = '-'
		index += 1
	}
	for count > 0 {
		count -= 1
		buffer[index] = reversed[count]
		index += 1
	}
	return canonical_append_bytes(encoder, buffer[:index], state)
}

@(private)
canonical_encode_float :: proc(
	encoder: ^Canonical_Encoder,
	value: Float,
	state: ^Semantic_Validation_State,
) -> Semantic_Validation_Error {
	buffer: [400]byte
	text, ok := binary64_format(f64(value), buffer[:])
	assert(ok)
	return canonical_append_text(encoder, text, state)
}

@(private)
canonical_append_fixed_decimal :: proc(
	encoder: ^Canonical_Encoder,
	value: u64,
	width: int,
	state: ^Semantic_Validation_State,
) -> Semantic_Validation_Error {
	buffer: [9]byte
	assert(0 <= width && width <= len(buffer))
	magnitude := value
	for index := width-1; index >= 0; index -= 1 {
		buffer[index] = byte(magnitude%10)+'0'
		magnitude /= 10
	}
	return canonical_append_bytes(encoder, buffer[:width], state)
}

@(private)
canonical_encode_local_date :: proc(
	encoder: ^Canonical_Encoder,
	value: temporal.Local_Date,
	state: ^Semantic_Validation_State,
) -> Semantic_Validation_Error {
	if err := canonical_append_fixed_decimal(encoder, u64(value.year), 4, state); err != nil {
		return err
	}
	if err := canonical_append_byte(encoder, '-', state); err != nil {
		return err
	}
	if err := canonical_append_fixed_decimal(encoder, u64(value.month), 2, state); err != nil {
		return err
	}
	if err := canonical_append_byte(encoder, '-', state); err != nil {
		return err
	}
	return canonical_append_fixed_decimal(encoder, u64(value.day), 2, state)
}

@(private)
canonical_encode_local_time :: proc(
	encoder: ^Canonical_Encoder,
	value: temporal.Local_Time,
	state: ^Semantic_Validation_State,
) -> Semantic_Validation_Error {
	if err := canonical_append_fixed_decimal(encoder, u64(value.hour), 2, state); err != nil {
		return err
	}
	if err := canonical_append_byte(encoder, ':', state); err != nil {
		return err
	}
	if err := canonical_append_fixed_decimal(encoder, u64(value.minute), 2, state); err != nil {
		return err
	}
	if err := canonical_append_byte(encoder, ':', state); err != nil {
		return err
	}
	if err := canonical_append_fixed_decimal(encoder, u64(value.second), 2, state); err != nil {
		return err
	}
	if value.nanosecond == 0 {
		return nil
	}
	if err := canonical_append_byte(encoder, '.', state); err != nil {
		return err
	}
	fraction := value.nanosecond
	width := 9
	for fraction%10 == 0 {
		fraction /= 10
		width -= 1
	}
	return canonical_append_fixed_decimal(encoder, u64(fraction), width, state)
}

@(private)
canonical_encode_local_date_time :: proc(
	encoder: ^Canonical_Encoder,
	value: temporal.Local_Date_Time,
	state: ^Semantic_Validation_State,
) -> Semantic_Validation_Error {
	if err := canonical_encode_local_date(encoder, value.date, state); err != nil {
		return err
	}
	if err := canonical_append_byte(encoder, 'T', state); err != nil {
		return err
	}
	return canonical_encode_local_time(encoder, value.time, state)
}

@(private)
canonical_encode_offset_date_time :: proc(
	encoder: ^Canonical_Encoder,
	value: temporal.Offset_Date_Time,
	state: ^Semantic_Validation_State,
) -> Semantic_Validation_Error {
	if err := canonical_encode_local_date_time(encoder, value.local, state); err != nil {
		return err
	}
	if value.offset.kind == .Unknown {
		return canonical_append_text(encoder, "-00:00", state)
	}
	if value.offset.minutes == 0 {
		return canonical_append_byte(encoder, 'Z', state)
	}
	minutes := int(value.offset.minutes)
	sign := byte('+')
	if minutes < 0 {
		sign = '-'
		minutes = -minutes
	}
	if err := canonical_append_byte(encoder, sign, state); err != nil {
		return err
	}
	if err := canonical_append_fixed_decimal(encoder, u64(minutes/60), 2, state); err != nil {
		return err
	}
	if err := canonical_append_byte(encoder, ':', state); err != nil {
		return err
	}
	return canonical_append_fixed_decimal(encoder, u64(minutes%60), 2, state)
}

@(private)
canonical_encode_value :: proc(
	encoder: ^Canonical_Encoder,
	value: ^Value,
	state: ^Semantic_Validation_State,
) -> Semantic_Validation_Error {
	switch item in value^ {
	case String:
		return canonical_encode_quoted_text(encoder, item, state)
	case Integer:
		return canonical_encode_integer(encoder, item, state)
	case Float:
		return canonical_encode_float(encoder, item, state)
	case Boolean:
		return canonical_append_text(encoder, "true" if item else "false", state)
	case temporal.Offset_Date_Time:
		return canonical_encode_offset_date_time(encoder, item, state)
	case temporal.Local_Date_Time:
		return canonical_encode_local_date_time(encoder, item, state)
	case temporal.Local_Date:
		return canonical_encode_local_date(encoder, item, state)
	case temporal.Local_Time:
		return canonical_encode_local_time(encoder, item, state)
	case Array:
		return canonical_encode_array(encoder, item, state)
	case Table:
		return canonical_encode_table(encoder, item, false, state)
	}
	unreachable()
}

@(private)
canonical_encode_array :: proc(
	encoder: ^Canonical_Encoder,
	array: Array,
	state: ^Semantic_Validation_State,
) -> Semantic_Validation_Error {
	if err := canonical_append_byte(encoder, '[', state); err != nil {
		return err
	}
	for &value, index in array {
		if index > 0 {
			if err := canonical_append_text(encoder, ", ", state); err != nil {
				return err
			}
		}
		if state != nil {
			if err := semantic_push_path(state, Path_Index(index)); err != nil {
				return err
			}
		}
		err := canonical_encode_value(encoder, &value, state)
		if state != nil {
			semantic_pop_path(state)
		}
		if err != nil {
			return err
		}
	}
	return canonical_append_byte(encoder, ']', state)
}

@(private)
canonical_encode_table :: proc(
	encoder: ^Canonical_Encoder,
	table: Table,
	root: bool,
	state: ^Semantic_Validation_State,
) -> Semantic_Validation_Error {
	if !root {
		if len(table) == 0 {
			return canonical_append_text(encoder, "{}", state)
		}
		if err := canonical_append_text(encoder, "{ ", state); err != nil {
			return err
		}
	}
	for &entry, index in table {
		if !root && index > 0 {
			if err := canonical_append_text(encoder, ", ", state); err != nil {
				return err
			}
		}
		if state != nil {
			if err := semantic_push_path(state, entry.key); err != nil {
				return err
			}
		}
		err := canonical_encode_quoted_text(encoder, entry.key, state)
		if err == nil {
			err = canonical_append_text(encoder, " = ", state)
		}
		if err == nil {
			err = canonical_encode_value(encoder, &entry.value, state)
		}
		if root && err == nil {
			err = canonical_append_byte(encoder, '\n', state)
		}
		if state != nil {
			semantic_pop_path(state)
		}
		if err != nil {
			return err
		}
	}
	if !root {
		return canonical_append_text(encoder, " }", state)
	}
	return nil
}

@(private)
canonical_encoding_plan_destroy :: proc(
	plan: ^Canonical_Encoding_Plan,
	loc := #caller_location,
) {
	if plan == nil || !plan.initialized {
		return
	}
	semantic_validation_state_destroy(&plan.validation, loc)
	plan^ = {}
}

@(private)
canonical_encoding_plan_build :: proc(
	doc: ^Document,
	max_depth: int,
	allocator: mem.Allocator,
	loc: runtime.Source_Code_Location,
) -> (plan: Canonical_Encoding_Plan, err: Unparse_Error) {
	if doc == nil || doc.allocator.procedure == nil || doc.root.allocator.procedure == nil {
		return {}, Unparse_Diagnostic{detail = Unparse_Data_Error_Kind.Invalid_Document}
	}

	init_error: runtime.Allocator_Error
	plan.validation, init_error = semantic_validation_state_init(
		allocator,
		doc.allocator,
		true,
		loc,
		max_depth = max_depth,
	)
	if init_error != nil {
		return {}, init_error
	}
	plan.initialized = true
	validation_error := semantic_validate_table(&plan.validation, doc.root, true, loc)
	if validation_error != nil {
		err = unparse_validation_error(validation_error)
		canonical_encoding_plan_destroy(&plan, loc)
		return
	}

	sizing: Canonical_Encoder
	sizing_error := canonical_encode_table(&sizing, doc.root, true, &plan.validation)
	if sizing_error != nil {
		err = unparse_validation_error(sizing_error)
		canonical_encoding_plan_destroy(&plan, loc)
		return
	}
	plan.encoded_size = sizing.count
	return
}

@(private)
canonical_encoding_plan_emit_allocated :: proc(
	plan: ^Canonical_Encoding_Plan,
	root: Table,
	allocator: mem.Allocator,
	loc: runtime.Source_Code_Location,
) -> (string, Unparse_Error) {
	if plan.encoded_size == 0 {
		return "", nil
	}
	memory, allocation_error := allocator_allocate(plan.encoded_size, allocator, false, loc)
	if allocation_error != nil {
		return "", allocation_error
	}
	if memory == nil {
		return "", runtime.Allocator_Error.Out_Of_Memory
	}
	output := mem.byte_slice(memory, plan.encoded_size)
	emitter := Canonical_Encoder{mode = .Output, output = output}
	emission_error := canonical_encode_table(&emitter, root, true, nil)
	assert(emission_error == nil && emitter.count == len(output))
	return string(output), nil
}

@(private)
canonical_encoding_plan_emit_writer :: proc(
	plan: ^Canonical_Encoding_Plan,
	root: Table,
	writer: io.Writer,
) -> Unparse_Error {
	if plan.encoded_size == 0 {
		return nil
	}
	emitter := Canonical_Encoder{mode = .Writer, writer = writer}
	emission_error := canonical_encode_table(&emitter, root, true, nil)
	assert(emission_error == nil)
	if emitter.writer_error != nil {
		return emitter.writer_error
	}
	assert(emitter.count == plan.encoded_size)
	return nil
}

@(require_results)
unparse :: proc(
	doc: ^Document,
	options: Marshal_Options = {},
	allocator := context.allocator,
	loc := #caller_location,
) -> (string, Unparse_Error) {
	if allocator.procedure == nil {
		return "", unparse_configuration_error(.Invalid_Allocator)
	}
	max_depth := options.max_depth
	if max_depth == 0 {
		max_depth = 128
	} else if max_depth < 1 || max_depth > SEMANTIC_MAX_DEPTH {
		return "", unparse_configuration_error(.Invalid_Max_Depth)
	}

	plan, plan_error := canonical_encoding_plan_build(doc, max_depth, allocator, loc)
	if plan_error != nil {
		return "", plan_error
	}
	defer canonical_encoding_plan_destroy(&plan, loc)
	return canonical_encoding_plan_emit_allocated(&plan, doc.root, allocator, loc)
}

@(require_results)
unparse_to_writer :: proc(
	writer: io.Writer,
	doc: ^Document,
	options: ^Marshal_Options,
	allocator := context.allocator,
	loc := #caller_location,
) -> Unparse_Error {
	if allocator.procedure == nil {
		return unparse_configuration_error(.Invalid_Allocator)
	}
	if options == nil {
		return unparse_configuration_error(.Nil_Options)
	}
	max_depth := options.max_depth
	if max_depth == 0 {
		max_depth = 128
	} else if max_depth < 1 || max_depth > SEMANTIC_MAX_DEPTH {
		return unparse_configuration_error(.Invalid_Max_Depth)
	}
	plan, plan_error := canonical_encoding_plan_build(doc, max_depth, allocator, loc)
	if plan_error != nil {
		return plan_error
	}
	defer canonical_encoding_plan_destroy(&plan, loc)
	return canonical_encoding_plan_emit_writer(&plan, doc.root, writer)
}

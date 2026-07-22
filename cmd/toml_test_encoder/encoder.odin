package main

import json "core:encoding/json"
import "core:fmt"
import "core:io"
import "core:unicode/utf8"
import "core:mem"
import "core:slice"
import "core:strings"
import toml "../.."
import temporal "external:temporal"

Adapter_Error_Kind :: enum u8 {
	Malformed_Input,
	Unsupported_Protocol_Value,
}

Adapter_Error :: union {
	Adapter_Error_Kind,
	io.Error,
}

Protocol_Array  :: [dynamic]Protocol_Value
Protocol_Object :: map[string]Protocol_Value
Protocol_Value  :: union #no_nil {
	string,
	Protocol_Array,
	Protocol_Object,
}

has_one_root_json_value :: proc(input: []byte) -> bool {
	index := 0
	for index < len(input) &&
	   (input[index] == ' ' || input[index] == '\t' ||
	    input[index] == '\n' || input[index] == '\r') {
		index += 1
	}
	if index == len(input) || (input[index] != '{' && input[index] != '[') {
		return false
	}

	depth := 0
	in_string := false
	escaped := false
	for index < len(input) {
		character := input[index]
		index += 1
		if in_string {
			if escaped {
				escaped = false
			} else if character == '\\' {
				escaped = true
			} else if character == '"' {
				in_string = false
			}
			continue
		}
		switch character {
		case '"': in_string = true
		case '{', '[': depth += 1
		case '}', ']':
			depth -= 1
			if depth == 0 {
				for index < len(input) &&
				   (input[index] == ' ' || input[index] == '\t' ||
				    input[index] == '\n' || input[index] == '\r') {
					index += 1
				}
				return index == len(input)
			}
		}
	}
	return false
}

Protocol_Parser :: struct {
	tokenizer: json.Tokenizer,
	current:   json.Token,
	allocator: mem.Allocator,
	failed:    bool,
}

protocol_parser_advance :: proc(parser: ^Protocol_Parser) {
	parser.current, _ = json.get_token(&parser.tokenizer)
}

protocol_parser_init :: proc(input: []byte, allocator: mem.Allocator) -> Protocol_Parser {
	parser := Protocol_Parser{
		tokenizer = json.make_tokenizer(string(input), .JSON, true),
		allocator = allocator,
	}
	protocol_parser_advance(&parser)
	return parser
}

protocol_parse_object :: proc(parser: ^Protocol_Parser) -> Protocol_Object {
	if parser.current.kind != .Open_Brace {
		parser.failed = true
		return nil
	}
	protocol_parser_advance(parser)
	object := make(Protocol_Object, allocator=parser.allocator)
	for parser.current.kind != .Close_Brace {
		if parser.current.kind != .String {
			parser.failed = true
			return nil
		}
		key, key_error := json.unquote_string(parser.current, .JSON, parser.allocator)
		if key_error != nil || key in object {
			parser.failed = true
			return nil
		}
		protocol_parser_advance(parser)
		if parser.current.kind != .Colon {
			parser.failed = true
			return nil
		}
		protocol_parser_advance(parser)
		value := protocol_parse_value(parser)
		if parser.failed {
			return nil
		}
		object[key] = value
		if parser.current.kind == .Comma {
			protocol_parser_advance(parser)
			continue
		}
		if parser.current.kind != .Close_Brace {
			parser.failed = true
			return nil
		}
	}
	protocol_parser_advance(parser)
	return object
}

protocol_parse_array :: proc(parser: ^Protocol_Parser) -> Protocol_Array {
	if parser.current.kind != .Open_Bracket {
		parser.failed = true
		return nil
	}
	protocol_parser_advance(parser)
	array, allocation_error := make(Protocol_Array, 0, parser.allocator)
	if allocation_error != nil {
		parser.failed = true
		return nil
	}
	for parser.current.kind != .Close_Bracket {
		value := protocol_parse_value(parser)
		if parser.failed {
			return nil
		}
		_ = append(&array, value)
		if parser.current.kind == .Comma {
			protocol_parser_advance(parser)
			continue
		}
		if parser.current.kind != .Close_Bracket {
			parser.failed = true
			return nil
		}
	}
	protocol_parser_advance(parser)
	return array
}

protocol_parse_value :: proc(parser: ^Protocol_Parser) -> Protocol_Value {
	#partial switch parser.current.kind {
	case .String:
		value, string_error := json.unquote_string(
			parser.current,
			.JSON,
			parser.allocator,
		)
		if string_error != nil {
			parser.failed = true
			return {}
		}
		protocol_parser_advance(parser)
		return Protocol_Value(value)
	case .Open_Brace:
		return Protocol_Value(protocol_parse_object(parser))
	case .Open_Bracket:
		return Protocol_Value(protocol_parse_array(parser))
	}
	parser.failed = true
	return {}
}

object_is_tagged_value :: proc(object: Protocol_Object) -> bool {
	if len(object) != 2 {
		return false
	}
	_, has_type := object["type"]
	_, has_value := object["value"]
	return has_type && has_value
}

parsed_kind_matches :: proc(kind: string, value: ^toml.Value) -> bool {
	switch kind {
	case "integer":
		_, ok := value^.(toml.Integer)
		return ok
	case "float":
		_, ok := value^.(toml.Float)
		return ok
	case "bool":
		_, ok := value^.(toml.Boolean)
		return ok
	case "datetime":
		_, ok := value^.(temporal.Offset_Date_Time)
		return ok
	case "datetime-local":
		_, ok := value^.(temporal.Local_Date_Time)
		return ok
	case "date-local":
		_, ok := value^.(temporal.Local_Date)
		return ok
	case "time-local":
		_, ok := value^.(temporal.Local_Time)
		return ok
	}
	return false
}

insert_parsed_scalar :: proc(
	table: ^toml.Table,
	key, kind, protocol_text: string,
) -> Adapter_Error {
	text := protocol_text
	owned_text := ""
	if kind == "float" &&
	   !strings.contains_any(text, ".eE") &&
	   text != "inf" && text != "+inf" && text != "-inf" &&
	   text != "nan" && text != "+nan" && text != "-nan" {
		owned_text = fmt.aprintf("%s.0", text)
		text = owned_text
	}
	defer if owned_text != "" {
		delete(owned_text)
	}

	source := fmt.aprintf("value = %s\n", text)
	defer delete(source)
	parsed, parse_error := toml.parse_string(source)
	if parse_error != nil {
		return Adapter_Error_Kind.Unsupported_Protocol_Value
	}
	defer toml.destroy_document(&parsed)
	value, found := toml.get(&parsed.root, "value")
	if !found || !parsed_kind_matches(kind, value) {
		return Adapter_Error_Kind.Unsupported_Protocol_Value
	}
	if mutation_error := toml.set(table, key, value); mutation_error != nil {
		return Adapter_Error_Kind.Unsupported_Protocol_Value
	}
	return nil
}

insert_tagged_value :: proc(
	table: ^toml.Table,
	key: string,
	object: Protocol_Object,
) -> Adapter_Error {
	type_node := object["type"]
	value_node := object["value"]
	kind, type_ok := type_node.(string)
	text, value_ok := value_node.(string)
	if !type_ok || !value_ok {
		return Adapter_Error_Kind.Unsupported_Protocol_Value
	}
	if kind == "string" {
		value := toml.Value(toml.String(text))
		if mutation_error := toml.set(table, key, &value); mutation_error != nil {
			return Adapter_Error_Kind.Unsupported_Protocol_Value
		}
		return nil
	}
	return insert_parsed_scalar(table, key, kind, text)
}

insert_object :: proc(
	table: ^toml.Table,
	key: string,
	object: Protocol_Object,
) -> Adapter_Error {
	if object_is_tagged_value(object) {
		return insert_tagged_value(table, key, object)
	}

	temporary, parse_error := toml.parse_string("")
	if parse_error != nil {
		return Adapter_Error_Kind.Unsupported_Protocol_Value
	}
	defer toml.destroy_document(&temporary)

	keys, allocation_error := make([]string, len(object))
	if allocation_error != nil {
		return Adapter_Error_Kind.Unsupported_Protocol_Value
	}
	defer delete(keys)
	index := 0
	for member_key in object {
		keys[index] = member_key
		index += 1
	}
	slice.sort(keys)
	for member_key in keys {
		if err := insert_protocol_value(&temporary.root, member_key, object[member_key]); err != nil {
			return err
		}
	}

	value := toml.Value(temporary.root)
	if mutation_error := toml.set(table, key, &value); mutation_error != nil {
		return Adapter_Error_Kind.Unsupported_Protocol_Value
	}
	return nil
}

protocol_value_owner :: proc(node: Protocol_Value) -> (toml.Value, Adapter_Error) {
	temporary, parse_error := toml.parse_string("")
	if parse_error != nil {
		return {}, Adapter_Error_Kind.Unsupported_Protocol_Value
	}
	defer toml.destroy_document(&temporary)
	if err := insert_protocol_value(&temporary.root, "value", node); err != nil {
		return {}, err
	}
	borrowed, found := toml.get(&temporary.root, "value")
	if !found {
		return {}, Adapter_Error_Kind.Unsupported_Protocol_Value
	}
	owned, clone_error := toml.clone_value(borrowed)
	if clone_error != nil {
		return {}, Adapter_Error_Kind.Unsupported_Protocol_Value
	}
	return owned, nil
}

insert_array :: proc(
	table: ^toml.Table,
	key: string,
	array: Protocol_Array,
) -> Adapter_Error {
	values, allocation_error := make(toml.Array, len(array))
	if allocation_error != nil {
		return Adapter_Error_Kind.Unsupported_Protocol_Value
	}
	owned := toml.Value(values)
	defer toml.destroy_value(&owned, context.allocator)

	for node, index in array {
		value, err := protocol_value_owner(node)
		if err != nil {
			return err
		}
		values[index] = value
	}
	if mutation_error := toml.set(table, key, &owned); mutation_error != nil {
		return Adapter_Error_Kind.Unsupported_Protocol_Value
	}
	return nil
}

insert_protocol_value :: proc(
	table: ^toml.Table,
	key: string,
	node: Protocol_Value,
) -> Adapter_Error {
	#partial switch item in node {
	case Protocol_Object:
		return insert_object(table, key, item)
	case Protocol_Array:
		return insert_array(table, key, item)
	}
	return Adapter_Error_Kind.Unsupported_Protocol_Value
}

build_protocol_document :: proc(root: Protocol_Object) -> (toml.Document, Adapter_Error) {
	doc, parse_error := toml.parse_string("")
	if parse_error != nil {
		return {}, Adapter_Error_Kind.Unsupported_Protocol_Value
	}

	keys, allocation_error := make([]string, len(root))
	if allocation_error != nil {
		toml.destroy_document(&doc)
		return {}, Adapter_Error_Kind.Unsupported_Protocol_Value
	}
	defer delete(keys)
	index := 0
	for key in root {
		keys[index] = key
		index += 1
	}
	slice.sort(keys)
	for key in keys {
		if err := insert_protocol_value(&doc.root, key, root[key]); err != nil {
			toml.destroy_document(&doc)
			return {}, err
		}
	}
	return doc, nil
}

encode_to_writer :: proc(input: []byte, writer: io.Writer) -> Adapter_Error {
	if !utf8.valid_string(string(input)) || !has_one_root_json_value(input) ||
	   !json.is_valid(input, .JSON, true) {
		return Adapter_Error_Kind.Malformed_Input
	}
	if len(input) > max(int)/64 {
		return Adapter_Error_Kind.Unsupported_Protocol_Value
	}
	scratch_size := max(64*1024, len(input)*64)
	scratch, scratch_error := make([]byte, scratch_size)
	if scratch_error != nil {
		return Adapter_Error_Kind.Unsupported_Protocol_Value
	}
	defer delete(scratch)
	scratch_arena: mem.Arena
	mem.arena_init(&scratch_arena, scratch)
	scratch_allocator := mem.arena_allocator(&scratch_arena)

	parser := protocol_parser_init(input, scratch_allocator)
	root := protocol_parse_object(&parser)
	if parser.failed || parser.current.kind != .EOF {
		return Adapter_Error_Kind.Unsupported_Protocol_Value
	}

	doc, build_error := build_protocol_document(root)
	if build_error != nil {
		return build_error
	}
	defer toml.destroy_document(&doc)
	options: toml.Marshal_Options
	if unparse_error := toml.unparse_to_writer(writer, &doc, &options); unparse_error != nil {
		if writer_error, writer_ok := unparse_error.(io.Error); writer_ok {
			return writer_error
		}
		return Adapter_Error_Kind.Unsupported_Protocol_Value
	}
	return nil
}

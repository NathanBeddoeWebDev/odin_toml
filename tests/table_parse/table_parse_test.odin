package table_parse_test

import "base:runtime"
import "core:mem"
import "core:testing"
import toml "../.."
import test_support "../support"

document_is_zero :: proc(doc: toml.Document) -> bool {
	return raw_data(doc.root) == nil && len(doc.root) == 0 && cap(doc.root) == 0 &&
	       doc.root.allocator.procedure == nil && doc.allocator.procedure == nil
}

value_for :: proc(t: ^testing.T, table: ^toml.Table, key: string) -> ^toml.Value {
	value, ok := toml.get(table, key)
	testing.expect(t, ok)
	return value
}

@(test)
test_dotted_assignment_creates_ordered_tables_at_the_public_parse_seam :: proc(t: ^testing.T) {
	doc, err := toml.parse_string("fruit.apple.color = \"red\"\nfruit.apple.count = 2\n")
	testing.expect(t, err == nil)
	if err != nil {
		return
	}
	defer toml.destroy_document(&doc)

	testing.expect_value(t, len(doc.root), 1)
	testing.expect_value(t, doc.root[0].key, "fruit")
	fruit, fruit_ok := value_for(t, &doc.root, "fruit").(toml.Table)
	testing.expect(t, fruit_ok)
	testing.expect_value(t, len(fruit), 1)
	apple, apple_ok := value_for(t, &fruit, "apple").(toml.Table)
	testing.expect(t, apple_ok)
	color, color_ok := value_for(t, &apple, "color").(toml.String)
	testing.expect(t, color_ok)
	testing.expect_value(t, color, "red")
	count, count_ok := value_for(t, &apple, "count").(toml.Integer)
	testing.expect(t, count_ok)
	testing.expect_value(t, count, toml.Integer(2))
}

parse_diagnostic_from :: proc(err: toml.Parse_Error) -> (toml.Parse_Diagnostic, bool) {
	return err.(toml.Parse_Diagnostic)
}

mutable_bytes :: proc(text: string) -> []byte {
	bytes, err := make([]byte, len(text))
	assert(err == nil)
	copy(bytes, transmute([]byte)text)
	return bytes
}

@(test)
test_stateful_byte_parse_never_borrows_header_keys_or_values :: proc(t: ^testing.T) {
	input := mutable_bytes("[\"owned.table\"]\n\"owned.key\" = \"owned value\"\n")
	defer delete(input)
	doc, err := toml.parse_bytes(input)
	testing.expect(t, err == nil)
	if err != nil {
		return
	}
	defer toml.destroy_document(&doc)
	for &byte in input {
		byte = 'x'
	}
	table, table_ok := value_for(t, &doc.root, "owned.table").(toml.Table)
	testing.expect(t, table_ok)
	text, text_ok := value_for(t, &table, "owned.key").(toml.String)
	testing.expect(t, text_ok)
	testing.expect_value(t, text, "owned value")
}

@(test)
test_standard_headers_allow_late_definition_of_implicit_parents :: proc(t: ^testing.T) {
	doc, err := toml.parse_string(
		"[a.b.c]\nleaf = 1\n[a]\nroot = 2\nb.other = 4\n[a.b]\nmiddle = 3\n",
	)
	testing.expect(t, err == nil)
	if err != nil {
		return
	}
	defer toml.destroy_document(&doc)

	a, a_ok := value_for(t, &doc.root, "a").(toml.Table)
	testing.expect(t, a_ok)
	root, root_ok := value_for(t, &a, "root").(toml.Integer)
	testing.expect(t, root_ok)
	testing.expect_value(t, root, toml.Integer(2))
	b, b_ok := value_for(t, &a, "b").(toml.Table)
	testing.expect(t, b_ok)
	middle, middle_ok := value_for(t, &b, "middle").(toml.Integer)
	testing.expect(t, middle_ok)
	testing.expect_value(t, middle, toml.Integer(3))
	other, other_ok := value_for(t, &b, "other").(toml.Integer)
	testing.expect(t, other_ok)
	testing.expect_value(t, other, toml.Integer(4))
	c, c_ok := value_for(t, &b, "c").(toml.Table)
	testing.expect(t, c_ok)
	leaf, leaf_ok := value_for(t, &c, "leaf").(toml.Integer)
	testing.expect(t, leaf_ok)
	testing.expect_value(t, leaf, toml.Integer(1))
}

@(test)
test_exact_decoded_path_components_do_not_alias_dots_case_or_normalization :: proc(t: ^testing.T) {
	doc, err := toml.parse_string(
		"\"a.b\" = 1\na.b = 2\nCase = 3\ncase = 4\n\"é\" = 5\n\"e\\u0301\" = 6\n",
	)
	testing.expect(t, err == nil)
	if err != nil {
		return
	}
	defer toml.destroy_document(&doc)

	dotted_data, dotted_data_ok := value_for(t, &doc.root, "a.b").(toml.Integer)
	testing.expect(t, dotted_data_ok)
	testing.expect_value(t, dotted_data, toml.Integer(1))
	a, a_ok := value_for(t, &doc.root, "a").(toml.Table)
	testing.expect(t, a_ok)
	path_dot, path_dot_ok := value_for(t, &a, "b").(toml.Integer)
	testing.expect(t, path_dot_ok)
	testing.expect_value(t, path_dot, toml.Integer(2))
	_, upper_ok := toml.get(&doc.root, "Case")
	_, lower_ok := toml.get(&doc.root, "case")
	_, composed_ok := toml.get(&doc.root, "é")
	_, decomposed_ok := toml.get(&doc.root, "é")
	testing.expect(t, upper_ok && lower_ok && composed_ok && decomposed_ok)
}

@(test)
test_repeated_and_dotted_defined_tables_report_exact_related_headers :: proc(t: ^testing.T) {
	cases := [?]struct {
		input:         string,
		kind:          toml.Parse_Definition_Error_Kind,
		existing:      toml.Parse_Definition_Form,
		attempted:     toml.Parse_Definition_Form,
		primary_start: int,
		primary_end:   int,
		related_start: int,
		related_end:   int,
	}{
		{"[a]\nx=1\n[a]\n", .Table_Redefined, .Standard_Table, .Standard_Table, 9, 10, 0, 3},
		{"a.b=1\n[a]\n", .Dotted_Table_Redefined, .Dotted_Table, .Standard_Table, 7, 8, 0, 1},
		{"a=1\n[a]\n", .Non_Table_Path_Component, .Key_Value, .Standard_Table, 5, 6, 0, 3},
	}
	for test_case in cases {
		doc, err := toml.parse_string(test_case.input)
		testing.expect(t, document_is_zero(doc))
		diagnostic, ok := parse_diagnostic_from(err)
		testing.expect(t, ok)
		definition, definition_ok := diagnostic.detail.(toml.Parse_Definition_Error)
		testing.expect(t, definition_ok)
		testing.expect_value(t, definition.kind, test_case.kind)
		testing.expect_value(t, definition.existing, test_case.existing)
		testing.expect_value(t, definition.attempted, test_case.attempted)
		testing.expect_value(t, diagnostic.primary.start.byte, test_case.primary_start)
		testing.expect_value(t, diagnostic.primary.end.byte, test_case.primary_end)
		testing.expect(t, diagnostic.related.ok)
		testing.expect_value(t, diagnostic.related.value.start.byte, test_case.related_start)
		testing.expect_value(t, diagnostic.related.value.end.byte, test_case.related_end)
	}
}

@(test)
test_headers_preserve_first_semantic_insertion_position :: proc(t: ^testing.T) {
	doc, err := toml.parse_string(
		"[z.y]\nleaf=1\n[z]\nlate=2\n[[items]]\nname=\"first\"\n[[items]]\nname=\"second\"\n",
	)
	testing.expect(t, err == nil)
	if err != nil {
		return
	}
	defer toml.destroy_document(&doc)
	testing.expect_value(t, len(doc.root), 2)
	testing.expect_value(t, doc.root[0].key, "z")
	testing.expect_value(t, doc.root[1].key, "items")
	z, z_ok := doc.root[0].value.(toml.Table)
	testing.expect(t, z_ok)
	testing.expect_value(t, z[0].key, "y")
	testing.expect_value(t, z[1].key, "late")
	items, items_ok := doc.root[1].value.(toml.Array)
	testing.expect(t, items_ok)
	testing.expect_value(t, len(items), 2)
}

@(test)
test_header_grammar_rejects_empty_unclosed_and_trailing_forms :: proc(t: ^testing.T) {
	cases := [?]struct {
		input:    string,
		expected: toml.Parse_Syntax,
		found:    toml.Parse_Syntax,
	}{
		{"[]\n", .Key, .Right_Bracket},
		{"[a", .Table_Header, .End_Of_Input},
		{"[[a]", .Array_Of_Tables_Header, .End_Of_Input},
		{"[a] trailing\n", .Expression_End, .Other},
	}
	for test_case in cases {
		doc, err := toml.parse_string(test_case.input)
		testing.expect(t, document_is_zero(doc))
		diagnostic, ok := parse_diagnostic_from(err)
		testing.expect(t, ok)
		grammar, grammar_ok := diagnostic.detail.(toml.Parse_Grammar_Error)
		testing.expect(t, grammar_ok)
		testing.expect(t, test_case.expected in grammar.expected)
		testing.expect_value(t, grammar.found, test_case.found)
	}
}

@(test)
test_key_and_header_separator_lexical_errors_keep_precedence :: proc(t: ^testing.T) {
	cases := [?]struct {
		input: string,
		kind:  toml.Parse_Lexical_Error,
	}{
		{"a\xc2\xa0=1\n", .Illegal_Character},
		{"[a\xc2\xa0]\n", .Illegal_Character},
		{"a\r=1\n", .Invalid_Newline},
		{"[a\r]\n", .Invalid_Newline},
	}
	for test_case in cases {
		doc, err := toml.parse_string(test_case.input)
		testing.expect(t, document_is_zero(doc))
		diagnostic, ok := parse_diagnostic_from(err)
		testing.expect(t, ok)
		lexical, lexical_ok := diagnostic.detail.(toml.Parse_Lexical_Error)
		testing.expect(t, lexical_ok)
		testing.expect_value(t, lexical, test_case.kind)
	}
}

@(test)
test_repeated_arrays_of_tables_and_children_bind_to_latest_parent_elements :: proc(t: ^testing.T) {
	input := `[[fruits]]
name = "apple"
[fruits.physical]
color = "red"
[[fruits.varieties]]
name = "red delicious"
[[fruits.varieties]]
name = "granny smith"
[[fruits]]
name = "banana"
[fruits.physical]
color = "yellow"
[[fruits.varieties]]
name = "plantain"
`
	doc, err := toml.parse_string(input)
	testing.expect(t, err == nil)
	if err != nil {
		return
	}
	defer toml.destroy_document(&doc)

	fruits, fruits_ok := value_for(t, &doc.root, "fruits").(toml.Array)
	testing.expect(t, fruits_ok)
	testing.expect_value(t, len(fruits), 2)
	apple, apple_ok := fruits[0].(toml.Table)
	banana, banana_ok := fruits[1].(toml.Table)
	testing.expect(t, apple_ok && banana_ok)
	apple_physical, apple_physical_ok := value_for(t, &apple, "physical").(toml.Table)
	banana_physical, banana_physical_ok := value_for(t, &banana, "physical").(toml.Table)
	testing.expect(t, apple_physical_ok && banana_physical_ok)
	apple_color, apple_color_ok := value_for(t, &apple_physical, "color").(toml.String)
	banana_color, banana_color_ok := value_for(t, &banana_physical, "color").(toml.String)
	testing.expect(t, apple_color_ok && banana_color_ok)
	testing.expect_value(t, apple_color, "red")
	testing.expect_value(t, banana_color, "yellow")
	apple_varieties, apple_varieties_ok := value_for(t, &apple, "varieties").(toml.Array)
	banana_varieties, banana_varieties_ok := value_for(t, &banana, "varieties").(toml.Array)
	testing.expect(t, apple_varieties_ok && banana_varieties_ok)
	testing.expect_value(t, len(apple_varieties), 2)
	testing.expect_value(t, len(banana_varieties), 1)
	red, red_ok := apple_varieties[0].(toml.Table)
	granny, granny_ok := apple_varieties[1].(toml.Table)
	plantain, plantain_ok := banana_varieties[0].(toml.Table)
	testing.expect(t, red_ok && granny_ok && plantain_ok)
	red_name, red_name_ok := value_for(t, &red, "name").(toml.String)
	granny_name, granny_name_ok := value_for(t, &granny, "name").(toml.String)
	plantain_name, plantain_name_ok := value_for(t, &plantain, "name").(toml.String)
	testing.expect(t, red_name_ok && granny_name_ok && plantain_name_ok)
	testing.expect_value(t, red_name, "red delicious")
	testing.expect_value(t, granny_name, "granny smith")
	testing.expect_value(t, plantain_name, "plantain")
}

ascii_source_position :: proc(input: string, byte_offset: int) -> toml.Source_Position {
	position := toml.Source_Position{byte = 0, line = 1, column = 1}
	for position.byte < byte_offset {
		assert(input[position.byte] < 0x80)
		if input[position.byte] == '\n' {
			position.line += 1
			position.column = 1
		} else {
			position.column += 1
		}
		position.byte += 1
	}
	return position
}

@(test)
test_definition_state_matrix_has_adjacent_permitted_and_forbidden_transitions :: proc(t: ^testing.T) {
	valid := [?]string{
		"a.b=1\na.c=2\n",
		"[a.b]\nx=1\n[a]\ny=2\n",
		"a.b=1\n[a.c]\nx=2\n",
		"[[a]]\n[[a]]\n",
		"[[a]]\n[a.b]\nx=1\n",
		"a=[]\n",
		"a={b=1}\n",
	}
	for input in valid {
		doc, err := toml.parse_string(input)
		testing.expect(t, err == nil)
		if err == nil {
			toml.destroy_document(&doc)
		}
	}

	invalid := [?]struct {
		input:         string,
		kind:          toml.Parse_Definition_Error_Kind,
		existing:      toml.Parse_Definition_Form,
		attempted:     toml.Parse_Definition_Form,
		primary_start: int,
		primary_end:   int,
		related_start: int,
		related_end:   int,
		path:          [2]string,
		path_source:   [2]toml.Source_Byte_Range,
		path_count:    int,
	}{
		{"a={}\na.b=1\n", .Inline_Table_Extended, .Inline_Table, .Dotted_Table, 5, 6, 0, 4, {"a", "b"}, {{5, 6}, {7, 8}}, 2},
		{"a=[]\n[a]\n", .Table_Array_Conflict, .Static_Array, .Standard_Table, 6, 7, 0, 4, {"a", ""}, {{6, 7}, {}}, 1},
		{"[a]\n[[a]]\n", .Array_Of_Tables_Conflict, .Standard_Table, .Array_Of_Tables, 6, 7, 0, 3, {"a", ""}, {{6, 7}, {}}, 1},
		{"[[a]]\n[a]\n", .Array_Of_Tables_Conflict, .Array_Of_Tables, .Standard_Table, 7, 8, 0, 5, {"a", ""}, {{7, 8}, {}}, 1},
		{"[[a.b]]\n[[a]]\n", .Array_Of_Tables_Conflict, .Implicit_Table, .Array_Of_Tables, 10, 11, 2, 3, {"a", ""}, {{10, 11}, {}}, 1},
		{"[q.p.child]\n[q]\np=1\n", .Table_Redefined, .Implicit_Table, .Key_Value, 16, 17, 3, 4, {"q", "p"}, {{13, 14}, {16, 17}}, 2},
		{"[q.p.child]\n[q]\np=[]\n", .Table_Array_Conflict, .Implicit_Table, .Static_Array, 16, 17, 3, 4, {"q", "p"}, {{13, 14}, {16, 17}}, 2},
		{"[q.p.child]\n[q]\np={}\n", .Table_Redefined, .Implicit_Table, .Inline_Table, 16, 17, 3, 4, {"q", "p"}, {{13, 14}, {16, 17}}, 2},
		{"a=1\na.b=2\n", .Non_Table_Path_Component, .Key_Value, .Dotted_Table, 4, 5, 0, 3, {"a", "b"}, {{4, 5}, {6, 7}}, 2},
		{"a=[]\na.b=2\n", .Table_Array_Conflict, .Static_Array, .Dotted_Table, 5, 6, 0, 4, {"a", "b"}, {{5, 6}, {7, 8}}, 2},
		{"a=[]\n[[a]]\n", .Array_Of_Tables_Conflict, .Static_Array, .Array_Of_Tables, 7, 8, 0, 4, {"a", ""}, {{7, 8}, {}}, 1},
		{"a=1\n[[a]]\n", .Array_Of_Tables_Conflict, .Key_Value, .Array_Of_Tables, 6, 7, 0, 3, {"a", ""}, {{6, 7}, {}}, 1},
		{"a.b=1\n[[a]]\n", .Array_Of_Tables_Conflict, .Dotted_Table, .Array_Of_Tables, 8, 9, 0, 1, {"a", ""}, {{8, 9}, {}}, 1},
		{"a={}\n[a]\n", .Inline_Table_Extended, .Inline_Table, .Standard_Table, 6, 7, 0, 4, {"a", ""}, {{6, 7}, {}}, 1},
		{"a={}\n[[a]]\n", .Array_Of_Tables_Conflict, .Inline_Table, .Array_Of_Tables, 7, 8, 0, 4, {"a", ""}, {{7, 8}, {}}, 1},
		{"[p.a]\n[p]\na=1\n", .Table_Redefined, .Standard_Table, .Key_Value, 10, 11, 0, 5, {"p", "a"}, {{7, 8}, {10, 11}}, 2},
		{"[p]\na.b=1\na=2\n", .Dotted_Table_Redefined, .Dotted_Table, .Key_Value, 10, 11, 4, 5, {"p", "a"}, {{1, 2}, {10, 11}}, 2},
		{"[[p.items]]\n[p]\nitems=1\n", .Array_Of_Tables_Conflict, .Array_Of_Tables, .Key_Value, 16, 21, 0, 11, {"p", "items"}, {{13, 14}, {16, 21}}, 2},
		{"[p.a]\n[p]\na=[]\n", .Table_Array_Conflict, .Standard_Table, .Static_Array, 10, 11, 0, 5, {"p", "a"}, {{7, 8}, {10, 11}}, 2},
		{"[[p.items]]\n[p]\nitems=[]\n", .Array_Of_Tables_Conflict, .Array_Of_Tables, .Static_Array, 16, 21, 0, 11, {"p", "items"}, {{13, 14}, {16, 21}}, 2},
		{"[p.a]\n[p]\na={}\n", .Table_Redefined, .Standard_Table, .Inline_Table, 10, 11, 0, 5, {"p", "a"}, {{7, 8}, {10, 11}}, 2},
		{"[p]\na.b=1\na=[]\n", .Table_Array_Conflict, .Dotted_Table, .Static_Array, 10, 11, 4, 5, {"p", "a"}, {{1, 2}, {10, 11}}, 2},
		{"[p]\na.b=1\na={}\n", .Dotted_Table_Redefined, .Dotted_Table, .Inline_Table, 10, 11, 4, 5, {"p", "a"}, {{1, 2}, {10, 11}}, 2},
		{"[[p.items]]\n[p]\nitems={}\n", .Array_Of_Tables_Conflict, .Array_Of_Tables, .Inline_Table, 16, 21, 0, 11, {"p", "items"}, {{13, 14}, {16, 21}}, 2},
		{"a=1\na=[]\n", .Duplicate_Key, .Key_Value, .Static_Array, 4, 5, 0, 3, {"a", ""}, {{4, 5}, {}}, 1},
		{"a=1\na={}\n", .Duplicate_Key, .Key_Value, .Inline_Table, 4, 5, 0, 3, {"a", ""}, {{4, 5}, {}}, 1},
		{"a=[]\na=1\n", .Duplicate_Key, .Static_Array, .Key_Value, 5, 6, 0, 4, {"a", ""}, {{5, 6}, {}}, 1},
		{"a=[]\na=[]\n", .Duplicate_Key, .Static_Array, .Static_Array, 5, 6, 0, 4, {"a", ""}, {{5, 6}, {}}, 1},
		{"a=[]\na={}\n", .Duplicate_Key, .Static_Array, .Inline_Table, 5, 6, 0, 4, {"a", ""}, {{5, 6}, {}}, 1},
		{"a={}\na=1\n", .Duplicate_Key, .Inline_Table, .Key_Value, 5, 6, 0, 4, {"a", ""}, {{5, 6}, {}}, 1},
		{"a={}\na=[]\n", .Duplicate_Key, .Inline_Table, .Static_Array, 5, 6, 0, 4, {"a", ""}, {{5, 6}, {}}, 1},
		{"a={}\na={}\n", .Duplicate_Key, .Inline_Table, .Inline_Table, 5, 6, 0, 4, {"a", ""}, {{5, 6}, {}}, 1},
	}
	for test_case in invalid {
		doc, err := toml.parse_string(test_case.input)
		testing.expect(t, document_is_zero(doc))
		diagnostic, ok := parse_diagnostic_from(err)
		testing.expect(t, ok)
		definition, definition_ok := diagnostic.detail.(toml.Parse_Definition_Error)
		testing.expect(t, definition_ok)
		testing.expect_value(t, definition.kind, test_case.kind)
		testing.expect_value(t, definition.existing, test_case.existing)
		testing.expect_value(t, definition.attempted, test_case.attempted)
		expected_primary := toml.Source_Range{
			ascii_source_position(test_case.input, test_case.primary_start),
			ascii_source_position(test_case.input, test_case.primary_end),
		}
		testing.expect_value(t, diagnostic.primary, expected_primary)
		testing.expect(t, diagnostic.related.ok)
		expected_related := toml.Source_Range{
			ascii_source_position(test_case.input, test_case.related_start),
			ascii_source_position(test_case.input, test_case.related_end),
		}
		testing.expect_value(t, diagnostic.related.value, expected_related)
		testing.expect_value(t, diagnostic.path.segment_count, u8(test_case.path_count))
		testing.expect_value(t, diagnostic.path.prefix_count, u8(test_case.path_count))
		testing.expect_value(t, diagnostic.path.total_segment_count, u16(test_case.path_count))
		testing.expect_value(t, diagnostic.path.omitted_segment_count, u16(0))
		testing.expect(t, !diagnostic.path.truncated)
		for index in 0..<test_case.path_count {
			key, key_ok := diagnostic.path.segments[index].(toml.Parse_Diagnostic_Key)
			testing.expect(t, key_ok)
			testing.expect_value(t, string(key.bytes[:key.prefix_length]), test_case.path[index])
			testing.expect_value(t, key.prefix_length, u8(len(test_case.path[index])))
			testing.expect_value(t, key.suffix_length, u8(0))
			testing.expect_value(t, key.decoded_byte_length, len(test_case.path[index]))
			testing.expect_value(t, key.omitted_byte_count, 0)
			testing.expect_value(t, key.source, test_case.path_source[index])
			testing.expect(t, !key.truncated)
		}
	}
}

@(test)
test_active_aot_definition_paths_use_current_header_component_sources :: proc(t: ^testing.T) {
	input := "[[outer]]\n[outer.child]\nvalue=1\nvalue=2\n"
	doc, err := toml.parse_string(input)
	testing.expect(t, document_is_zero(doc))
	diagnostic, ok := parse_diagnostic_from(err)
	testing.expect(t, ok)
	definition, definition_ok := diagnostic.detail.(toml.Parse_Definition_Error)
	testing.expect(t, definition_ok)
	testing.expect_value(t, definition.kind, toml.Parse_Definition_Error_Kind.Duplicate_Key)
	testing.expect_value(t, definition.existing, toml.Parse_Definition_Form.Key_Value)
	testing.expect_value(t, definition.attempted, toml.Parse_Definition_Form.Key_Value)
	testing.expect_value(t, diagnostic.primary, toml.Source_Range{
		ascii_source_position(input, 32), ascii_source_position(input, 37),
	})
	testing.expect(t, diagnostic.related.ok)
	testing.expect_value(t, diagnostic.related.value, toml.Source_Range{
		ascii_source_position(input, 24), ascii_source_position(input, 31),
	})
	testing.expect_value(t, diagnostic.path.segment_count, u8(4))
	testing.expect_value(t, diagnostic.path.prefix_count, u8(4))
	testing.expect_value(t, diagnostic.path.total_segment_count, u16(4))
	testing.expect_value(t, diagnostic.path.omitted_segment_count, u16(0))
	testing.expect(t, !diagnostic.path.truncated)

	outer, outer_ok := diagnostic.path.segments[0].(toml.Parse_Diagnostic_Key)
	index, index_ok := diagnostic.path.segments[1].(toml.Path_Index)
	child, child_ok := diagnostic.path.segments[2].(toml.Parse_Diagnostic_Key)
	leaf, leaf_ok := diagnostic.path.segments[3].(toml.Parse_Diagnostic_Key)
	testing.expect(t, outer_ok && index_ok && child_ok && leaf_ok)
	testing.expect_value(t, string(outer.bytes[:outer.prefix_length]), "outer")
	testing.expect_value(t, outer.prefix_length, u8(5))
	testing.expect_value(t, outer.suffix_length, u8(0))
	testing.expect_value(t, outer.decoded_byte_length, 5)
	testing.expect_value(t, outer.omitted_byte_count, 0)
	testing.expect_value(t, outer.source, toml.Source_Byte_Range{11, 16})
	testing.expect(t, !outer.truncated)
	testing.expect_value(t, index, toml.Path_Index(0))
	testing.expect_value(t, string(child.bytes[:child.prefix_length]), "child")
	testing.expect_value(t, child.prefix_length, u8(5))
	testing.expect_value(t, child.suffix_length, u8(0))
	testing.expect_value(t, child.decoded_byte_length, 5)
	testing.expect_value(t, child.omitted_byte_count, 0)
	testing.expect_value(t, child.source, toml.Source_Byte_Range{17, 22})
	testing.expect(t, !child.truncated)
	testing.expect_value(t, string(leaf.bytes[:leaf.prefix_length]), "value")
	testing.expect_value(t, leaf.prefix_length, u8(5))
	testing.expect_value(t, leaf.suffix_length, u8(0))
	testing.expect_value(t, leaf.decoded_byte_length, 5)
	testing.expect_value(t, leaf.omitted_byte_count, 0)
	testing.expect_value(t, leaf.source, toml.Source_Byte_Range{32, 37})
	testing.expect(t, !leaf.truncated)
}

@(test)
test_aot_conflicts_report_current_component_and_latest_element_header_ranges :: proc(t: ^testing.T) {
	input := "[[a]]\nx=1\n[[a]]\nx=2\n[a]\n"
	doc, err := toml.parse_string(input)
	testing.expect(t, document_is_zero(doc))
	diagnostic, ok := parse_diagnostic_from(err)
	testing.expect(t, ok)
	definition, definition_ok := diagnostic.detail.(toml.Parse_Definition_Error)
	testing.expect(t, definition_ok)
	testing.expect_value(t, definition.kind, toml.Parse_Definition_Error_Kind.Array_Of_Tables_Conflict)
	testing.expect_value(t, definition.existing, toml.Parse_Definition_Form.Array_Of_Tables)
	testing.expect_value(t, definition.attempted, toml.Parse_Definition_Form.Standard_Table)
	testing.expect_value(t, diagnostic.primary, toml.Source_Range{
		ascii_source_position(input, 21), ascii_source_position(input, 22),
	})
	testing.expect(t, diagnostic.related.ok)
	testing.expect_value(t, diagnostic.related.value, toml.Source_Range{
		ascii_source_position(input, 10), ascii_source_position(input, 15),
	})
	testing.expect_value(t, diagnostic.path.segment_count, u8(1))
	testing.expect_value(t, diagnostic.path.prefix_count, u8(1))
	testing.expect_value(t, diagnostic.path.total_segment_count, u16(1))
	testing.expect_value(t, diagnostic.path.omitted_segment_count, u16(0))
	testing.expect(t, !diagnostic.path.truncated)
	key, key_ok := diagnostic.path.segments[0].(toml.Parse_Diagnostic_Key)
	testing.expect(t, key_ok)
	testing.expect_value(t, string(key.bytes[:key.prefix_length]), "a")
	testing.expect_value(t, key.prefix_length, u8(1))
	testing.expect_value(t, key.suffix_length, u8(0))
	testing.expect_value(t, key.decoded_byte_length, 1)
	testing.expect_value(t, key.omitted_byte_count, 0)
	testing.expect_value(t, key.source, toml.Source_Byte_Range{21, 22})
	testing.expect(t, !key.truncated)
}

@(test)
test_table_and_aot_depth_count_semantic_keys_and_latest_element_indexes :: proc(t: ^testing.T) {
	valid, valid_error := toml.parse_string("[a]\nx=1\n", {max_depth = 2})
	testing.expect(t, valid_error == nil)
	if valid_error == nil {
		toml.destroy_document(&valid)
	}
	aot, aot_error := toml.parse_string("[[a]]\n", {max_depth = 2})
	testing.expect(t, aot_error == nil)
	if aot_error == nil {
		toml.destroy_document(&aot)
	}

	failed, failed_error := toml.parse_string("[[a]]\n", {max_depth = 1})
	testing.expect(t, document_is_zero(failed))
	diagnostic, ok := parse_diagnostic_from(failed_error)
	testing.expect(t, ok)
	limit, limit_ok := diagnostic.detail.(toml.Parse_Limit_Error)
	testing.expect(t, limit_ok)
	testing.expect_value(t, limit, toml.Parse_Limit_Error.Maximum_Depth_Exceeded)
	testing.expect_value(t, diagnostic.path.total_segment_count, u16(2))
	_, key_ok := diagnostic.path.segments[0].(toml.Parse_Diagnostic_Key)
	_, index_ok := diagnostic.path.segments[1].(toml.Path_Index)
	testing.expect(t, key_ok && index_ok)
}

@(test)
test_decoded_dotted_duplicate_paths_retain_current_and_prior_definition_ranges :: proc(t: ^testing.T) {
	input := "a.\"b.c\" = 1\na.\"b\\u002Ec\" = 2\n"
	doc, err := toml.parse_string(input)
	testing.expect(t, document_is_zero(doc))
	diagnostic, ok := parse_diagnostic_from(err)
	testing.expect(t, ok)
	definition, definition_ok := diagnostic.detail.(toml.Parse_Definition_Error)
	testing.expect(t, definition_ok)
	testing.expect_value(t, definition.kind, toml.Parse_Definition_Error_Kind.Duplicate_Key)
	testing.expect_value(t, diagnostic.primary.start.byte, 14)
	testing.expect_value(t, diagnostic.primary.end.byte, 24)
	testing.expect(t, diagnostic.related.ok)
	testing.expect_value(t, diagnostic.related.value.start.byte, 0)
	testing.expect_value(t, diagnostic.related.value.end.byte, 11)
	testing.expect_value(t, diagnostic.path.total_segment_count, u16(2))
	leaf, leaf_ok := diagnostic.path.segments[1].(toml.Parse_Diagnostic_Key)
	testing.expect(t, leaf_ok)
	testing.expect_value(t, string(leaf.bytes[:leaf.prefix_length]), "b.c")
	testing.expect_value(t, leaf.source, toml.Source_Byte_Range{14, 24})
}

parse_stateful_input :: proc(
	input: string,
	use_bytes: bool,
	allocator: runtime.Allocator,
) -> (toml.Document, toml.Parse_Error) {
	if use_bytes {
		return toml.parse_bytes(transmute([]byte)input, allocator = allocator)
	}
	return toml.parse_string(input, allocator = allocator)
}

run_stateful_allocation_sweep :: proc(t: ^testing.T, input: string, use_bytes: bool) {
	backing := context.allocator
	baseline_events: [2048]test_support.Allocator_Event
	baseline_live: [512]test_support.Live_Allocation
	baseline: test_support.Observed_Allocator
	test_support.observed_allocator_init(&baseline, backing, baseline_events[:], baseline_live[:])
	baseline_allocator := test_support.observed_allocator(&baseline)
	baseline_doc, baseline_error := parse_stateful_input(input, use_bytes, baseline_allocator)
	testing.expect(t, baseline_error == nil)
	allocation_count := baseline.allocation_request_count
	if baseline_error == nil {
		toml.destroy_document(&baseline_doc)
	}
	testing.expect(t, allocation_count > 0)
	testing.expect_value(t, baseline.live_count, 0)

	for fail_at in 1..=allocation_count {
		events: [2048]test_support.Allocator_Event
		live: [512]test_support.Live_Allocation
		observed: test_support.Observed_Allocator
		test_support.observed_allocator_init(&observed, backing, events[:], live[:])
		observed.fail_at_allocation = fail_at
		selected := test_support.observed_allocator(&observed)
		rejecting: test_support.Rejecting_Allocator
		context.allocator = test_support.rejecting_allocator(&rejecting)
		doc, err := parse_stateful_input(input, use_bytes, selected)
		context.allocator = backing

		testing.expect(t, document_is_zero(doc))
		allocator_error, allocator_ok := err.(runtime.Allocator_Error)
		testing.expect(t, allocator_ok)
		testing.expect_value(t, allocator_error, runtime.Allocator_Error.Out_Of_Memory)
		testing.expect_value(t, observed.live_count, 0)
		testing.expect_value(t, observed.foreign_release_count, 0)
		testing.expect_value(t, rejecting.allocation_attempt_count, 0)
	}

	after_events: [2048]test_support.Allocator_Event
	after_live: [512]test_support.Live_Allocation
	after: test_support.Observed_Allocator
	test_support.observed_allocator_init(&after, backing, after_events[:], after_live[:])
	after.fail_at_allocation = allocation_count+1
	after_allocator := test_support.observed_allocator(&after)
	after_doc, after_error := parse_stateful_input(input, use_bytes, after_allocator)
	testing.expect(t, after_error == nil)
	if after_error == nil {
		toml.destroy_document(&after_doc)
	}
	testing.expect_value(t, after.live_count, 0)

	exact_events: [2048]test_support.Allocator_Event
	exact_live: [512]test_support.Live_Allocation
	exact: test_support.Observed_Allocator
	test_support.observed_allocator_init(&exact, backing, exact_events[:], exact_live[:])
	exact.fail_at_allocation = max(1, allocation_count/2)
	exact.failure_error = .Invalid_Argument
	exact_allocator := test_support.observed_allocator(&exact)
	exact_doc, exact_error := parse_stateful_input(input, use_bytes, exact_allocator)
	testing.expect(t, document_is_zero(exact_doc))
	exact_allocator_error, exact_ok := exact_error.(runtime.Allocator_Error)
	testing.expect(t, exact_ok)
	testing.expect_value(t, exact_allocator_error, runtime.Allocator_Error.Invalid_Argument)
	testing.expect_value(t, exact.live_count, 0)
	testing.expect_value(t, exact.foreign_release_count, 0)
	context.allocator = backing
}

@(test)
test_official_decoder_regressions_reject_dotted_extension_of_explicit_tables_and_arrays_of_tables :: proc(t: ^testing.T) {
	cases := [?]struct {
		input:         string,
		kind:          toml.Parse_Definition_Error_Kind,
		existing:      toml.Parse_Definition_Form,
		primary_start: int,
		primary_end:   int,
		related_end:   int,
		path:          [4]string,
		path_count:    int,
	}{
		{
			"[[tab.arr]]\n[tab]\narr.val1=1\n",
			.Array_Of_Tables_Conflict,
			.Array_Of_Tables,
			18, 21, 11,
			{"tab", "arr", "", ""},
			2,
		},
		{
			"[a.b.c]\nz=9\n[a]\nb.c.t=\"x\"\n",
			.Table_Redefined,
			.Standard_Table,
			18, 19, 7,
			{"a", "b", "c", ""},
			3,
		},
		{
			"[a.b.c.d]\nz=9\n[a]\nb.c.d.k.t=\"x\"\n",
			.Table_Redefined,
			.Standard_Table,
			22, 23, 9,
			{"a", "b", "c", "d"},
			4,
		},
		{
			"[[a.b]]\n[a]\nb.y=2\n",
			.Array_Of_Tables_Conflict,
			.Array_Of_Tables,
			12, 13, 7,
			{"a", "b", "", ""},
			2,
		},
		{
			"[a.b.c]\nz=9\n[[unrelated]]\nx=1\n[a]\nb.c.t=\"x\"\n",
			.Table_Redefined,
			.Standard_Table,
			36, 37, 7,
			{"a", "b", "c", ""},
			3,
		},
	}
	for test_case in cases {
		doc, err := toml.parse_string(test_case.input)
		testing.expect(t, document_is_zero(doc))
		if err == nil {
			toml.destroy_document(&doc)
		}
		diagnostic, ok := parse_diagnostic_from(err)
		testing.expect(t, ok)
		if !ok {
			continue
		}
		definition, definition_ok := diagnostic.detail.(toml.Parse_Definition_Error)
		testing.expect(t, definition_ok)
		if !definition_ok {
			continue
		}
		testing.expect_value(t, definition.kind, test_case.kind)
		testing.expect_value(t, definition.existing, test_case.existing)
		testing.expect_value(t, definition.attempted, toml.Parse_Definition_Form.Dotted_Table)
		testing.expect_value(t, diagnostic.primary, toml.Source_Range{
			ascii_source_position(test_case.input, test_case.primary_start),
			ascii_source_position(test_case.input, test_case.primary_end),
		})
		testing.expect(t, diagnostic.related.ok)
		testing.expect_value(t, diagnostic.related.value, toml.Source_Range{
			ascii_source_position(test_case.input, 0),
			ascii_source_position(test_case.input, test_case.related_end),
		})
		testing.expect_value(t, diagnostic.path.segment_count, u8(test_case.path_count))
		testing.expect_value(t, diagnostic.path.prefix_count, u8(test_case.path_count))
		testing.expect_value(t, diagnostic.path.total_segment_count, u16(test_case.path_count))
		testing.expect_value(t, diagnostic.path.omitted_segment_count, u16(0))
		testing.expect(t, !diagnostic.path.truncated)
		for index in 0..<test_case.path_count {
			key, key_ok := diagnostic.path.segments[index].(toml.Parse_Diagnostic_Key)
			testing.expect(t, key_ok)
			if key_ok {
				testing.expect_value(t, string(key.bytes[:key.prefix_length]), test_case.path[index])
			}
		}
	}

	valid_neighbors := [?]string{
		"[[tab.arr]]\nval1=1\n",
		"[a.b.c]\nz=9\nt=\"x\"\n",
		"[a]\nb.c.d.k.t=\"x\"\n",
		"[[a.b]]\ny=2\n",
		"[a.b.c]\nz=9\n[[unrelated]]\nx=1\n[a.b.c.extra]\nt=\"x\"\n",
	}
	for input in valid_neighbors {
		doc, err := toml.parse_string(input)
		testing.expect(t, err == nil)
		if err == nil {
			toml.destroy_document(&doc)
		}
	}
}

@(test)
test_stateful_parse_allocation_failure_is_transactional_at_every_ordinal :: proc(t: ^testing.T) {
	input := `root.dotted = "owned"
[root.child]
value = [{ nested = "also owned" }]
[[root.items]]
name = "first"
[root.items.detail]
flag = true
[[root.items]]
name = "second"
[[root.items.children]]
name = "nested"
`
	run_stateful_allocation_sweep(t, input, false)
	run_stateful_allocation_sweep(t, input, true)
}

@(test)
test_external_lifetime_stateful_parse_owns_and_logically_destroys_tree :: proc(t: ^testing.T) {
	buffer: [256 * 1024]byte
	arena: mem.Arena
	mem.arena_init(&arena, buffer[:])
	external: test_support.External_Lifetime_Allocator
	test_support.external_lifetime_allocator_init(&external, mem.arena_allocator(&arena), true)
	allocator := test_support.external_lifetime_allocator(&external)
	doc, err := toml.parse_string(
		"root.child = \"owned\"\n[[root.items]]\nname = \"first\"\n[[root.items]]\nname = \"second\"\n",
		allocator = allocator,
	)
	testing.expect(t, err == nil)
	testing.expect(t, arena.offset > 0)
	if err == nil {
		toml.destroy_document(&doc)
	}
	testing.expect(t, document_is_zero(doc))
	testing.expect_value(t, external.release_attempt_count, 0)
	testing.expect_value(t, external.free_all_count, 0)
	mem.arena_free_all(&arena)
}

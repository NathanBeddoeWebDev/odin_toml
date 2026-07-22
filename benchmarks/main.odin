package benchmarks

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:time"
import toml ".."

PARSE_INPUT :: #load("fixtures/parse-mixed.toml")
SIZE_NESTED :: #load("fixtures/size-nested.toml")
SIZE_AOT :: #load("fixtures/size-aot.toml")
SIZE_MIXED :: #load("fixtures/size-mixed.toml")
SAMPLE_COUNT :: 5

Benchmark_Proc :: #type proc(iterations: int) -> (elapsed_ns: i64, checksum: u64)

checksum_bytes :: proc(value: []byte, initial: u64 = 14695981039346656037) -> u64 {
	result := initial
	for byte in value {
		result = (result ~ u64(byte))*1099511628211
	}
	return result
}

checksum_string :: proc(value: string, initial: u64 = 14695981039346656037) -> u64 {
	result := initial
	for index in 0..<len(value) {
		result = (result ~ u64(value[index]))*1099511628211
	}
	return result
}

elapsed_nanoseconds :: proc(start, end: time.Tick) -> i64 {
	return time.duration_nanoseconds(time.tick_diff(start, end))
}

benchmark_parse :: proc(iterations: int) -> (i64, u64) {
	checksum: u64
	start := time.tick_now()
	for _ in 0..<iterations {
		doc, err := toml.parse_bytes(PARSE_INPUT)
		assert(err == nil)
		checksum += u64(len(doc.root))
		toml.destroy_document(&doc)
	}
	return elapsed_nanoseconds(start, time.tick_now()), checksum
}

benchmark_semantic_encode :: proc(iterations: int) -> (i64, u64) {
	doc, parse_error := toml.parse_bytes(PARSE_INPUT)
	assert(parse_error == nil)
	defer toml.destroy_document(&doc)
	checksum: u64
	start := time.tick_now()
	for _ in 0..<iterations {
		encoded, err := toml.unparse(&doc)
		assert(err == nil)
		checksum = checksum_string(encoded, checksum)
		delete(encoded)
	}
	return elapsed_nanoseconds(start, time.tick_now()), checksum
}

Typed_Record :: struct {
	name:    string,
	values:  []i64,
	enabled: bool,
}

TYPED_INPUT :: `name = "typed"
values = [1, 2, 3, 5, 8, 13, 21, 34]
enabled = true
`

cleanup_typed_record :: proc(value: ^Typed_Record) {
	if len(value.name) > 0 {
		assert(delete(value.name) == nil)
	}
	if raw_data(value.values) != nil {
		assert(delete(value.values) == nil)
	}
	value^ = {}
}

benchmark_typed_marshal :: proc(iterations: int) -> (i64, u64) {
	values := []i64{1, 2, 3, 5, 8, 13, 21, 34}
	source := Typed_Record{name = "typed", values = values, enabled = true}
	checksum: u64
	start := time.tick_now()
	for _ in 0..<iterations {
		encoded, err := toml.marshal(source)
		assert(err == nil)
		checksum = checksum_bytes(encoded, checksum)
		delete(encoded)
	}
	return elapsed_nanoseconds(start, time.tick_now()), checksum
}

benchmark_typed_unmarshal :: proc(iterations: int) -> (i64, u64) {
	checksum: u64
	start := time.tick_now()
	for _ in 0..<iterations {
		destination: Typed_Record
		err := toml.unmarshal_string(TYPED_INPUT, &destination)
		assert(err == nil)
		checksum += u64(len(destination.name)+len(destination.values))
		cleanup_typed_record(&destination)
	}
	return elapsed_nanoseconds(start, time.tick_now()), checksum
}

benchmark_ordered_table :: proc(iterations: int) -> (i64, u64) {
	root, allocation_error := make(toml.Table, 256)
	assert(allocation_error == nil)
	for index in 0..<len(root) {
		key := fmt.aprintf("entry-%03d", index)
		root[index] = {key = key, value = toml.Value(toml.Integer(index))}
	}
	doc := toml.Document{root = root, allocator = context.allocator}
	defer toml.destroy_document(&doc)

	checksum: u64
	start := time.tick_now()
	for _ in 0..<iterations {
		value, found := toml.get(&doc.root, "entry-255")
		assert(found)
		checksum += u64(value^.(toml.Integer))
		_, missing := toml.get(&doc.root, "entry-missing")
		assert(!missing)
	}
	return elapsed_nanoseconds(start, time.tick_now()), checksum
}

append_text :: proc(buffer: ^[dynamic]byte, text: string) {
	for index in 0..<len(text) {
		append(buffer, text[index])
	}
}

make_depth_input :: proc(depth: int) -> [dynamic]byte {
	buffer, allocation_error := make([dynamic]byte, 0, 2048)
	assert(allocation_error == nil)
	append_text(&buffer, "root = ")
	for _ in 0..<depth {
		append_text(&buffer, "{ child = ")
	}
	append_text(&buffer, "1")
	for _ in 0..<depth {
		append_text(&buffer, " }")
	}
	append_text(&buffer, "\n")
	return buffer
}

make_wide_input :: proc(key_count: int) -> [dynamic]byte {
	buffer, allocation_error := make([dynamic]byte, 0, key_count*16)
	assert(allocation_error == nil)
	for index in 0..<key_count {
		line := fmt.aprintf("key-%05d = 0\n", index)
		append_text(&buffer, line)
		delete(line)
	}
	return buffer
}

benchmark_wide_parse :: proc(input: []byte, iterations: int) -> (i64, u64) {
	checksum: u64
	start := time.tick_now()
	for _ in 0..<iterations {
		document, err := toml.parse_bytes(input)
		assert(err == nil)
		checksum += u64(len(document.root))
		toml.destroy_document(&document)
	}
	return elapsed_nanoseconds(start, time.tick_now()), checksum
}

cleanup_wide_map :: proc(mapping: ^map[string]i64) {
	for key in mapping^ {
		assert(delete(key) == nil)
	}
	assert(delete(mapping^) == nil)
	mapping^ = nil
}

benchmark_wide_unmarshal :: proc(input: []byte, iterations: int) -> (i64, u64) {
	checksum: u64
	start := time.tick_now()
	for _ in 0..<iterations {
		destination: map[string]i64
		err := toml.unmarshal(input, &destination)
		assert(err == nil)
		checksum += u64(len(destination))
		cleanup_wide_map(&destination)
	}
	return elapsed_nanoseconds(start, time.tick_now()), checksum
}

benchmark_depth :: proc(iterations: int) -> (i64, u64) {
	input := make_depth_input(64)
	defer delete(input)
	checksum: u64
	start := time.tick_now()
	for _ in 0..<iterations {
		doc, err := toml.parse_bytes(input[:])
		assert(err == nil)
		checksum += u64(len(doc.root))
		toml.destroy_document(&doc)
	}
	return elapsed_nanoseconds(start, time.tick_now()), checksum
}

Map_Root :: struct {
	values: map[string]i64,
}

benchmark_map_sort :: proc(iterations: int) -> (i64, u64) {
	mapping := make(map[string]i64)
	keys: [256]string
	for reverse_index in 0..<len(keys) {
		index := len(keys)-1-reverse_index
		keys[reverse_index] = fmt.aprintf("key-%03d", index)
		mapping[keys[reverse_index]] = i64(index)
	}
	defer {
		delete(mapping)
		for key in keys {
			delete(key)
		}
	}
	source := Map_Root{values = mapping}
	checksum: u64
	start := time.tick_now()
	for _ in 0..<iterations {
		encoded, err := toml.marshal(source)
		assert(err == nil)
		checksum = checksum_bytes(encoded, checksum)
		delete(encoded)
	}
	return elapsed_nanoseconds(start, time.tick_now()), checksum
}

Codec_Integer :: distinct i64
Codec_Root :: struct {
	values: [128]Codec_Integer,
}
Codec_State :: struct {
	marshal_calls:   int,
	unmarshal_calls: int,
}

marshal_codec_integer :: proc(
	source: any,
	user_data: rawptr,
	allocator: mem.Allocator,
	loc: runtime.Source_Code_Location,
) -> (toml.Value, toml.Codec_Callback_Error) {
	_, _ = allocator, loc
	state := (^Codec_State)(user_data)
	state.marshal_calls += 1
	return toml.Value(toml.Integer((^Codec_Integer)(source.data)^)), nil
}

unmarshal_codec_integer :: proc(
	source: ^toml.Value,
	destination: any,
	user_data: rawptr,
	allocator: mem.Allocator,
	loc: runtime.Source_Code_Location,
) -> toml.Codec_Callback_Error {
	_, _ = allocator, loc
	state := (^Codec_State)(user_data)
	state.unmarshal_calls += 1
	(^Codec_Integer)(destination.data)^ = Codec_Integer(source^.(toml.Integer))
	return nil
}

benchmark_codec_heavy :: proc(iterations: int) -> (i64, u64) {
	state: Codec_State
	registry, registry_error := toml.init_codec_registry()
	assert(registry_error == nil)
	defer toml.destroy_codec_registry(&registry)
	assert(toml.register_marshaler(
		&registry,
		typeid_of(Codec_Integer),
		{procedure = marshal_codec_integer, user_data = &state},
	) == nil)
	assert(toml.register_unmarshaler(
		&registry,
		typeid_of(Codec_Integer),
		{procedure = unmarshal_codec_integer, user_data = &state},
	) == nil)
	source: Codec_Root
	for index in 0..<len(source.values) {
		source.values[index] = Codec_Integer(index)
	}

	checksum: u64
	start := time.tick_now()
	for _ in 0..<iterations {
		encoded, marshal_error := toml.marshal(source, {codecs = &registry})
		assert(marshal_error == nil)
		destination: Codec_Root
		unmarshal_error := toml.unmarshal(
			encoded, &destination, {codecs = &registry},
		)
		assert(unmarshal_error == nil)
		checksum += u64(destination.values[len(destination.values)-1])
		delete(encoded)
	}
	checksum += u64(state.marshal_calls+state.unmarshal_calls)
	return elapsed_nanoseconds(start, time.tick_now()), checksum
}

emit_benchmark :: proc(name: string, operations: int, procedure: Benchmark_Proc) {
	// Warmups are deliberately not reported.
	_, _ = procedure(1)
	for _ in 0..<SAMPLE_COUNT {
		elapsed, checksum := procedure(operations)
		assert(elapsed > 0)
		fmt.printf("benchmark\t%s\t%d\t%d\t%d\n", name, operations, elapsed, checksum)
	}
}

run_performance :: proc() {
	emit_benchmark("parse", 300, benchmark_parse)
	emit_benchmark("semantic-encode", 300, benchmark_semantic_encode)
	emit_benchmark("typed-marshal", 250, benchmark_typed_marshal)
	emit_benchmark("typed-unmarshal", 250, benchmark_typed_unmarshal)
	emit_benchmark("ordered-table", 100000, benchmark_ordered_table)
	emit_benchmark("depth", 50, benchmark_depth)
	emit_benchmark("map-sort", 100, benchmark_map_sort)
	emit_benchmark("codec-heavy", 50, benchmark_codec_heavy)
}

emit_scaling_benchmark :: proc(
	name: string,
	key_count, operations: int,
	procedure: proc(input: []byte, iterations: int) -> (i64, u64),
) {
	input := make_wide_input(key_count)
	defer delete(input)
	_, _ = procedure(input[:], 1)
	for _ in 0..<SAMPLE_COUNT {
		elapsed, checksum := procedure(input[:], operations)
		assert(elapsed > 0)
		fmt.printf(
			"scaling\t%s\t%d\t%d\t%d\t%d\n",
			name, key_count, operations, elapsed, checksum,
		)
	}
}

run_wide_scaling :: proc() {
	emit_scaling_benchmark("parse", 100, 500, benchmark_wide_parse)
	emit_scaling_benchmark("parse", 1000, 50, benchmark_wide_parse)
	emit_scaling_benchmark("parse", 10000, 5, benchmark_wide_parse)
	emit_scaling_benchmark("typed-unmarshal", 100, 300, benchmark_wide_unmarshal)
	emit_scaling_benchmark("typed-unmarshal", 1000, 30, benchmark_wide_unmarshal)
	emit_scaling_benchmark("typed-unmarshal", 10000, 3, benchmark_wide_unmarshal)
}

emit_size :: proc(name: string, input: []byte) {
	doc, parse_error := toml.parse_bytes(input)
	assert(parse_error == nil)
	defer toml.destroy_document(&doc)
	encoded, unparse_error := toml.unparse(&doc)
	assert(unparse_error == nil)
	defer delete(encoded)
	fmt.printf(
		"size\t%s\t%d\t%d\t%d\n",
		name,
		len(input),
		len(encoded),
		checksum_string(encoded),
	)
}

run_encoded_sizes :: proc() {
	emit_size("nested-tables", SIZE_NESTED)
	emit_size("arrays-of-tables", SIZE_AOT)
	emit_size("mixed-values", SIZE_MIXED)
}

main :: proc() {
	if len(os.args) != 2 {
		fmt.eprintln("usage: benchmarks <performance|encoded-size|wide-scaling>")
		os.exit(2)
	}
	switch os.args[1] {
	case "performance":
		run_performance()
	case "encoded-size":
		run_encoded_sizes()
	case "wide-scaling":
		run_wide_scaling()
	case:
		fmt.eprintln("usage: benchmarks <performance|encoded-size|wide-scaling>")
		os.exit(2)
	}
}

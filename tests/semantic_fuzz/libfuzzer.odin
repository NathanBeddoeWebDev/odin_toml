package semantic_fuzz_test

import "base:runtime"

keep_semantic_fuzz_runtime_import :: proc() {
	_ = runtime.default_context()
}

when TOML_LIBFUZZER_DRIVER {
@(export)
LLVMFuzzerTestOneInput :: proc "c" (data: [^]u8, size: uintptr) -> i32 {
	context = runtime.default_context()
	input := data[:int(size)]
	coverage_strict_parse_target(input)
	coverage_valid_utf8_parser_mutation_target(input)
	coverage_parse_unparse_target(input)
	coverage_semantic_lifecycle_target(input)
	coverage_writer_validation_target(input)
	return 0
}
}

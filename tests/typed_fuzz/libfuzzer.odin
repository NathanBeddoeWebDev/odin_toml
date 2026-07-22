package typed_fuzz_test

import "base:runtime"

keep_typed_fuzz_runtime_import :: proc() {
	_ = runtime.default_context()
}

when TOML_LIBFUZZER_DRIVER {
@(export)
LLVMFuzzerTestOneInput :: proc "c" (data: [^]u8, size: uintptr) -> i32 {
	context = runtime.default_context()
	coverage_typed_codec_target(data[:int(size)])
	return 0
}
}

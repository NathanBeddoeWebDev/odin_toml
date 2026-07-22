package main

import "base:runtime"

keep_encoder_runtime_import :: proc() {
	_ = runtime.default_context()
}

when TOML_LIBFUZZER_DRIVER {
@(export)
LLVMFuzzerTestOneInput :: proc "c" (data: [^]u8, size: uintptr) -> i32 {
	context = runtime.default_context()
	run_encoder_adapter_coverage_target(data[:int(size)])
	return 0
}
}

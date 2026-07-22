package main

import "base:runtime"

keep_decoder_runtime_import :: proc() {
	_ = runtime.default_context()
}

when TOML_LIBFUZZER_DRIVER {
@(export)
LLVMFuzzerTestOneInput :: proc "c" (data: [^]u8, size: uintptr) -> i32 {
	context = runtime.default_context()
	run_decoder_adapter_coverage_target(data[:int(size)])
	return 0
}
}

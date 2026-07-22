package main

import "core:os"

TOML_LIBFUZZER_DRIVER :: #config(TOML_LIBFUZZER_DRIVER, false)

keep_encoder_cli_import :: proc() {
	_ = os.args
}

when !TOML_LIBFUZZER_DRIVER {
main :: proc() {
	fuzz_target := len(os.args) == 2 && os.args[1] == "--fuzz-target"
	if len(os.args) != 1 && !fuzz_target {
		_, _ = os.write_string(
			os.stderr,
			"usage: toml-test-encoder [--fuzz-target]\n",
		)
		os.exit(2)
	}
	input, read_error := os.read_entire_file(os.stdin, context.allocator)
	if read_error != nil {
		_, _ = os.write_string(os.stderr, "toml-test encoder: could not read input\n")
		os.exit(1)
	}
	defer delete(input)

	if fuzz_target {
		run_encoder_adapter_coverage_target(input)
		return
	}
	if err := encode_to_writer(input, os.to_writer(os.stdout)); err != nil {
		_, _ = os.write_string(os.stderr, "toml-test encoder: rejected input\n")
		os.exit(1)
	}
}
}

package main

import "core:os"

TOML_LIBFUZZER_DRIVER :: #config(TOML_LIBFUZZER_DRIVER, false)

keep_decoder_cli_import :: proc() {
	_ = os.args
}

when !TOML_LIBFUZZER_DRIVER {
main :: proc() {
	input, read_error := os.read_entire_file(os.stdin, context.allocator)
	if read_error != nil {
		_, _ = os.write_string(os.stderr, "toml-test decoder: could not read input\n")
		os.exit(1)
	}
	defer delete(input)

	if err := decode_to_writer(input, os.to_writer(os.stdout)); err != nil {
		_, _ = os.write_string(os.stderr, "toml-test decoder: rejected input\n")
		os.exit(1)
	}
}
}

package typed_fuzz_test

import "core:os"

TOML_LIBFUZZER_DRIVER :: #config(TOML_LIBFUZZER_DRIVER, false)

keep_typed_fuzz_cli_import :: proc() {
	_ = os.args
}

when !TOML_LIBFUZZER_DRIVER {
main :: proc() {
	if len(os.args) != 1 {
		_, _ = os.write_string(os.stderr, "usage: typed-fuzz < artifact\n")
		os.exit(2)
	}
	input, err := os.read_entire_file(os.stdin, context.allocator)
	if err != nil {
		_, _ = os.write_string(os.stderr, "typed-fuzz: could not read stdin\n")
		os.exit(2)
	}
	defer delete(input)
	coverage_typed_codec_target(input)
}
}

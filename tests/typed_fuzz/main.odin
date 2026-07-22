package typed_fuzz_test

import "core:os"

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

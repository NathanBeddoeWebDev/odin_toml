package main

import "core:os"

main :: proc() {
	input, read_error := os.read_entire_file(os.stdin, context.allocator)
	if read_error != nil {
		_, _ = os.write_string(os.stderr, "toml-test encoder: could not read input\n")
		os.exit(1)
	}
	defer delete(input)

	if err := encode_to_writer(input, os.to_writer(os.stdout)); err != nil {
		_, _ = os.write_string(os.stderr, "toml-test encoder: rejected input\n")
		os.exit(1)
	}
}

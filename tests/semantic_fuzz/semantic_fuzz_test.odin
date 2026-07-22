package semantic_fuzz_test

import "core:testing"
import "core:unicode/utf8"
import test_support "../support"

ARBITRARY_BYTE_CASE_COUNT :: 4_096
VALID_SEED_MUTATION_CASE_COUNT :: 2_048

VALID_TOML_SEEDS := [?]string{
	"",
	"# comment\n",
	`name = "odin"` + "\n",
	`unicode = "α🪶"` + "\n",
	`numbers = [0, -1, 3.5, inf, nan]` + "\n",
	`temporal = 2024-02-29T23:59:60.123456789-00:00` + "\n",
	`inline = { first = true, nested = [1, 2, 3] }` + "\n",
	`[table]` + "\n" + `"dotted.key" = "value"` + "\n",
	`[[products]]` + "\n" + `name = "first"` + "\n" +
		`[[products]]` + "\n" + `name = "second"` + "\n",
}

@(test)
test_arbitrary_strict_parse_and_composition_targets_run_4096_replayable_cases :: proc(t: ^testing.T) {
	random := test_support.replay_random_from_test(t, "semantic-fuzz-arbitrary-bytes")
	storage: [256]byte
	for _ in 0..<ARBITRARY_BYTE_CASE_COUNT {
		count := test_support.replay_int_max(&random, len(storage)+1)
		_ = test_support.replay_read(&random, storage[:count])
		run_strict_parse_target(t, storage[:count])
		run_parse_unparse_composition_target(t, storage[:count])
	}
}

@(test)
test_valid_utf8_seed_mutation_target_runs_2048_replayable_cases :: proc(t: ^testing.T) {
	random := test_support.replay_random_from_test(t, "semantic-fuzz-valid-utf8-mutations")
	storage: [1024]byte
	for case_index in 0..<VALID_SEED_MUTATION_CASE_COUNT {
		seed := VALID_TOML_SEEDS[case_index%len(VALID_TOML_SEEDS)]
		mutated := mutate_valid_utf8_seed(&random, seed, storage[:])
		testing.expect(t, utf8.valid_string(string(mutated)))
		run_valid_utf8_parser_mutation_target(t, mutated)
	}
}

@(test)
test_semantic_lifecycle_target_replays_public_owner_workflows :: proc(t: ^testing.T) {
	fixtures := [?][]byte{
		{},
		{0},
		{1, 2, 3, 4},
		{0xff, 0x00, 0x7f, 0x80},
		transmute([]byte)(string("semantic-lifecycle")),
	}
	for fixture in fixtures {
		run_semantic_lifecycle_target(t, fixture)
	}
}

@(test)
test_malformed_owner_target_validates_without_salvage_destruction :: proc(t: ^testing.T) {
	for selector in 0..<MALFORMED_OWNER_KIND_COUNT {
		run_malformed_owner_validation_target(t, byte(selector))
	}
}

@(test)
test_writer_target_varies_counts_and_errors_with_canonical_prefixes_and_no_retries :: proc(t: ^testing.T) {
	random := test_support.replay_random_from_test(t, "semantic-fuzz-writer")
	input: [16]byte
	for _ in 0..<512 {
		_ = test_support.replay_read(&random, input[:])
		run_writer_validation_target(t, input[:])
	}
}

@(test)
test_public_fuzz_regression_fixtures_remain_stable :: proc(t: ^testing.T) {
	fixtures := [?][]byte{
		{0xef, 0xbb, 0xbf},
		{0xc0, 0x80},
		transmute([]byte)(string("value = truex\n")),
		transmute([]byte)(string("value = 1e+\n")),
		transmute([]byte)(string("[a]\n[a]\n")),
		transmute([]byte)(string("value = [1, { nested = [2, 3] }] trailing\n")),
	}
	for fixture in fixtures {
		run_strict_parse_target(t, fixture)
		run_parse_unparse_composition_target(t, fixture)
	}
}

package test_support

import "core:testing"

@(test)
test_replay_random_reproduces_known_sequence :: proc(t: ^testing.T) {
	seed := u64(0x0123456789abcdef)
	expected := [6]u64{
		9014021337574587592,
		14266440638627216865,
		1326953789384816860,
		12745025038352371988,
		11985490262472868168,
		771865028046304372,
	}
	first := replay_random_init(seed)
	second := replay_random_init(seed)
	testing.expect_value(t, first.seed, seed)
	testing.expect_value(t, second.seed, seed)

	for expected_value in expected {
		testing.expect_value(t, replay_u64(&first), expected_value)
		testing.expect_value(t, replay_u64(&second), expected_value)
	}
}

@(test)
test_replay_random_from_test_reports_runner_seed :: proc(t: ^testing.T) {
	random := replay_random_from_test(t, "support-self-test")
	testing.expect_value(t, random.seed, t.seed)

	replayed := replay_random_init(t.seed)
	for _ in 0 ..< 8 {
		testing.expect_value(t, replay_int_max(&random, 1000), replay_int_max(&replayed, 1000))
	}
}

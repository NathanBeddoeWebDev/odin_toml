package test_support

import "core:log"
import "core:math/rand"
import "core:testing"

// Replay_Random owns independent PRNG state and retains the exact seed needed
// to reproduce its sequence. It never uses context.random_generator.
Replay_Random :: struct {
	seed:  u64,
	state: rand.Default_Random_State,
}

@(require_results)
replay_random_init :: proc(seed: u64) -> Replay_Random {
	return {
		seed = seed,
		state = rand.create(seed),
	}
}

// replay_random_from_test both records the test runner's replay seed in the
// helper and emits the exact define accepted by `odin test`.
@(require_results)
replay_random_from_test :: proc(t: ^testing.T, label := "") -> Replay_Random {
	if label == "" {
		log.infof("Replay with -define:ODIN_TEST_RANDOM_SEED=%v", t.seed)
	} else {
		log.infof("Replay %s with -define:ODIN_TEST_RANDOM_SEED=%v", label, t.seed)
	}
	return replay_random_init(t.seed)
}

@(require_results)
replay_u64 :: proc(random: ^Replay_Random) -> u64 {
	return rand.uint64(rand.default_random_generator(&random.state))
}

@(require_results)
replay_int_max :: proc(random: ^Replay_Random, exclusive_max: int) -> int {
	return rand.int_max(exclusive_max, rand.default_random_generator(&random.state))
}

replay_read :: proc(random: ^Replay_Random, destination: []byte) -> int {
	return rand.read(destination, rand.default_random_generator(&random.state))
}

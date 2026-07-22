# TOML adversarial test support

This package is test-only. Runtime `toml` and vendored `temporal` sources must not import it; the public API check rejects that dependency.

## Allocators

- `Observed_Allocator` wraps a backing allocator, records every allocator call in caller-owned storage, tracks live allocations, rejects and records foreign releases, and can fail a one-based allocating-call ordinal through `fail_at_allocation`.
- `Rejecting_Allocator` is installed as `context.allocator` while the operation under test receives a selected allocator explicitly. A zero call count proves the operation did not fall back to ambient allocation.
- `External_Lifetime_Allocator` denies individual frees. Its reporting mode advertises allocator features without `.Free`; its unsupported mode returns `.Mode_Not_Implemented` for feature queries. The caller remains responsible for the backing allocator's external reset or destruction.

All instrumentation storage is borrowed. The helpers allocate nothing themselves, so their observations do not perturb allocation ordinals.

## Writer

`Scripted_Writer` borrows a step list and caller-owned call/byte buffers. `Scripted_Write` can return any exact count, full length, `-1`, or one byte past the input, paired with any `io.Error`. Writes beyond the script succeed fully. Every stream-procedure invocation, including queries and unsupported modes, receives one call record. Check both dropped counters before relying on a trace.

## Random replay

`Replay_Random` owns independent deterministic generator state and retains its seed. `replay_random_from_test` uses `testing.T.seed` and logs the exact `-define:ODIN_TEST_RANDOM_SEED=<seed>` replay argument.

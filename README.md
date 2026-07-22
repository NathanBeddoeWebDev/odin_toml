# odin_toml

Standalone Odin packages for strict TOML 1.1 documents and allocation-free temporal values.

The package accepts no permissive, recovery, legacy, or extension mode. Public declarations, ownership behavior, canonical bytes, and diagnostics are frozen against the pinned Reference Odin compiler.

## Packages

- Repository root: package `toml`
- [`temporal/`](temporal): package `temporal`

`toml` imports `temporal`; `temporal` does not import `toml`. External consumers can use a relative import or map the repository into an Odin collection.

## Consumer contract

- [`docs/consumer-guide.md`](docs/consumer-guide.md) defines parse/clone ownership, borrow invalidation, mutation, allocated/writer output, typed cleanup, allocator lifetime modes, and codec registry concurrency.
- [`docs/compatibility.md`](docs/compatibility.md) defines strictness, package-wide normal RTTI, the supported compiler/target/mode matrix, SemVer policy, and non-goals.
- [`examples/consumer_contract`](examples/consumer_contract/main.odin) executes mutation, canonical allocated/writer identity, typed marshal/unmarshal, directionally paired codecs, and zero-owner error results.
- [`examples/semantic_lifecycle`](examples/semantic_lifecycle/main.odin) executes parse, borrowed lookup, clone, and destruction.
- [`examples/typed_unmarshal_cleanup`](examples/typed_unmarshal_cleanup/main.odin) executes complete and partial typed cleanup with individually freeing and external-lifetime allocators.

## Semantic ownership

Successful parse and clone calls return owners. `get` returns only a borrowed pointer: do not destroy it, and do not retain it across structural mutation or destruction of its containing table. A successful `clone_value` creates an independent standalone owner.

`set` borrows and validates its key and value, deep-clones committed ownership through the target table's retained allocator, preserves replacement position, and appends new keys. It rejects zero tables and malformed text, temporals, containers, duplicates, cycles, ownership aliases, allocator mismatches, and local paths deeper than 256 without changing the table. `remove` requires a valid acyclic, exclusively owned, allocator-consistent table; it destroys the removed owner and stably compacts the table, so removing and reinserting a key appends it. Any successful structural mutation invalidates all value pointers borrowed from that table.

- Release a `Document` with `destroy_document`.
- Release a standalone cloned `Value` with `destroy_value` and the same allocator used to clone it.
- Both destroy operations zero the supplied owner and are idempotent.
- With an external-lifetime allocator, destruction ends logical ownership; reclaim physical storage through that allocator's lifetime.

The executable [`examples/semantic_lifecycle`](examples/semantic_lifecycle/main.odin) demonstrates an initialized empty document and the difference between a borrowed `get` result and an owned deep clone. [`examples/consumer_contract`](examples/consumer_contract/main.odin) additionally executes structural mutation and both canonical output forms.

## Codec registry lifecycle

Create each caller-owned `Codec_Registry` with `init_codec_registry`, register marshal and unmarshal callbacks independently by exact `typeid`, and release the registry with `destroy_codec_registry`. The registry retains the selected allocator and owns only its two lookup maps. Callback code and `user_data` remain application-owned and must outlive every call that borrows them.

Complete registration before sharing a registry. Concurrent read-only lookup through a frozen registry is supported; callers must separately synchronize any mutable callback state reached through `user_data`. Registration or destruction while any TOML call or other reader is using the registry is a caller contract violation. Destruction zeros the owner and is idempotent. There is no package-global codec registry.

Typed marshal consults an exact registered source `typeid` before generic, named, temporal, or wrapper handling. `any` is unwrapped first, `omitempty` is decided before lookup, and map keys never consult codecs. A marshaler runs once for each encountered node during preflight and returns an owned semantic `Value`, never raw TOML. It must allocate every escaping string, key, array, and table with the supplied allocator and return no partial owner with an error. The package validates, caches, canonically emits, and destroys each successful returned value on every later path. Callback failure codes must be nonzero; callback allocator errors remain exact allocator errors.

A marshaler borrows its source `any`; an unmarshaler borrows its semantic `^Value`. Both borrows, every reachable pointer, and the unmarshaler's destination `any` are valid only until the callback returns. Callbacks must not retain those borrows, mutate their source, or directly or indirectly re-enter `marshal`, `marshal_to_writer`, `unmarshal`, or `unmarshal_string` during an active callback. They compose by producing or consuming semantic values directly; semantic clone/destruction and temporal operations remain available under their normal ownership contracts.

## Typed unmarshal ownership

Typed unmarshal strictly parses and preflights the complete binding before installation. Matched owning slots must be exactly zero; allocation-free scalar defaults are allowed. Missing and `toml:"-"` fields are neither inspected nor changed. Every installed string, container, map key, pointer, and owning child belongs to the allocator passed to `unmarshal` or `unmarshal_string`; input storage is never installed by alias.

An installation allocation failure can leave earlier ownership-safe units installed. Strings commit only after cloning, slices and dynamic arrays install their storage before elements, pointers install their allocation before pointee children, and optional unions activate their sole alternative before children. Maps preallocate storage and normally commit only complete key/value pairs in semantic insertion order. A first successful custom unmarshaler nested in a staged map value commits that stable entry immediately; if a later child fails, the recursively cleanable partial entry remains caller-owned while later staged entries are removed. The destination owns every committed unit immediately, including on error.

Typed unmarshal consults an exact registered destination `typeid` before named-type, temporal, generic, or wrapper handling; map keys and `any` destinations never consult codecs. The callback runs once during ordered installation with the exact clean destination slot, borrowed ranged semantic value, registered `user_data`, selected allocator, and caller location. Success transfers codec-specific installed ownership to the application. Before returning an error, a callback must clean its attempt and restore its complete slot to exact zero; the package also zeros that slot before propagating a nonzero application code as `Unmarshal_Codec_Error` or an allocator error unchanged. Earlier independent commit units may remain.

There is intentionally no generic typed destructor. With an arbitrary-order individually freeing allocator, recursively clean children before containers: delete and zero strings; clean slice or dynamic-array elements before deleting and zeroing the container; clean owned map keys and values before deleting and zeroing the map; clean a pointee before freeing and niling its pointer; and clean an optional union's active alternative before setting it to nil. Struct and fixed-array cleanup recursively visits owning fields or elements. With an external-lifetime allocator, zero or discard owning slots without individual deletion, then reclaim the allocator's complete lifetime. A wholly zero-start projected destination is the generally safe mechanical-cleanup pattern after partial installation; pre-existing ownership in missing or ignored fields needs application-specific provenance.

The executable [`examples/typed_unmarshal_cleanup`](examples/typed_unmarshal_cleanup/main.odin) demonstrates complete and partial cleanup for both individually freeing and external-lifetime allocators.

## Reproducible checks

The supported compiler is pinned in [`toolchain/odin.lock`](toolchain/odin.lock). From a clean checkout with that compiler on `PATH`:

```sh
scripts/prepare_test_dependencies.sh
scripts/check_documentation.sh
scripts/check.sh
```

The documentation check compiles and executes every public example in normal (`-o:minimal`) and optimized (`-o:speed`) modes. The complete check captures `odin version` and `odin report` in `build/reports/compiler.txt`, checks the frozen generated API snapshots and tracked release manifest, rejects runtime oracle dependencies, runs the complete correctness suite, and compiles both external consumers. CI runs the suite natively on Linux amd64/arm64, macOS amd64/arm64, and Windows amd64; the exact sanitizer scope and compatibility policy are documented in [`docs/compatibility.md`](docs/compatibility.md).

The complete `toml` package requires normal RTTI because its frozen typed-binding declarations use `any`. `ODIN_NO_RTTI` builds are unsupported, including semantic-only consumers. [`design-reviews/001-reference-odin-no-rtti.md`](design-reviews/001-reference-odin-no-rtti.md) records the pinned-compiler evidence and approved resolution; `scripts/probe_no_rtti.sh` remains only as a historical reproducer.

## Baselines and release evidence

Reproduce the eight public-API benchmark categories and inline canonical encoded-size observations with:

```sh
scripts/record_benchmarks.py performance --output /tmp/odin-toml-performance.json
scripts/record_benchmarks.py encoded-size --output /tmp/odin-toml-inline-sizes.json
```

The commands and committed results are documented in [`benchmarks/README.md`](benchmarks/README.md). They are observations only: no duration or size is a release threshold.

[`release/manifest.json`](release/manifest.json) binds every compiler/dependency pin, conformance report, deterministic seed, allocator/writer sweep, platform/mode job, and sanitizer/race artifact. [`release/README.md`](release/README.md) documents clean-checkout reproduction and the fail-closed CI assembly of the SHA-256-indexed `release-bundle`; unresolved skips, expected failures, sanitizer/race/memory findings, and minimized fuzz defects are rejected.

## Test-only dependency pins

- `toml-lang/toml-test` v2.2.0 at `ce08da1ddb075d1c7596d663c7fcba9a2ae02c5c`, TOML version `1.1.0`: [`tests/corpus/toml-test.lock`](tests/corpus/toml-test.lock)
- Ryu at `4c0618b0e44f7ef027ebae05d2cc7812048f7c8f`: [`tests/oracle/ryu.lock`](tests/oracle/ryu.lock)

Their upstream licenses are retained beside the locks. Prepare exact test-only source checkouts and build the official corpus runner with:

```sh
scripts/prepare_test_dependencies.sh
```

All generated sources and tools stay under ignored `build/`. Neither source is vendored, imported, linked, or otherwise used by the runtime packages.

Run the pinned official TOML 1.1 decoder and encoder gates with:

```sh
scripts/check_toml_test_decoder.sh
scripts/check_toml_test_encoder.sh
```

The gates build test-only public-API adapters, invoke the official runner with literal `-toml=1.1.0`, and reject any valid, invalid, or encoder failure or skip. The encoder adapter translates the official tagged-JSON protocol into semantic owners through public lifecycle operations and emits only through `unparse_to_writer`. Reviewed machine-readable results and compiler/platform provenance are preserved in [`tests/corpus/toml-test-decoder-report.json`](tests/corpus/toml-test-decoder-report.json) and [`tests/corpus/toml-test-encoder-report.json`](tests/corpus/toml-test-encoder-report.json).

Replayable generated semantic trees exercise parse/unparse equivalence, canonical byte idempotence, clone independence, insertion and array order, repeated determinism, and allocated/writer byte identity in `tests/semantic_properties`.

Generated typed/codec properties live in `tests/typed_fuzz`. They round-trip bounded application structs through their represented TOML values, including maps, sequences, pointers, optionals, renamed/ignored/defaulted fields, and exact paired codecs. The same suite checks deterministic callback order, transactional callback slots, immutable unknown-field preflight, recursively cleanable installation failures, active cycles, marshal-only `any`, allocator ordinals, writer prefixes/errors, and successful codec-temporary cleanup. Its minimized public-API fixtures record replay seed `123456789` beside each artifact.

Early public-seam fuzz targets live in `tests/semantic_fuzz`, `tests/typed_fuzz`, and beside both conformance adapters. Every ordinary run reports its `ODIN_TEST_RANDOM_SEED`; semantic targets cover 4,096 arbitrary byte cases and 2,048 valid-UTF-8 seed mutations, apply semantic and canonical round-trip checks to accepted TOML, validate malformed owners without unsafe salvage destruction, and vary writer counts/errors while checking canonical prefixes and no retries. Adapter targets additionally exercise 4,096 arbitrary inputs with observed allocation cleanup. Minimized findings are retained as deterministic literal fixtures in the nearest public-seam suite.

`tests/semantic_fuzz` builds as a one-artifact replay target with the selectors `strict-parse`, `valid-utf8`, `parse-unparse`, `semantic-lifecycle`, and `writer-validation`. `tests/typed_fuzz` builds as one typed/codec target whose artifact bytes deterministically select bounded round-trip, ownership-fault, writer-fault, allocation-fault, cycle, unknown-field, and `any` shapes. The test encoder's `--fuzz-target` mode provides the malformed tagged-JSON target. These entrypoints read one artifact from standard input, assert public-seam invariants, and are suitable for the later sanitizer-backed coverage-guided campaign without changing the replay contract.

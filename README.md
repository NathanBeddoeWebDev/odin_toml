# odin_toml

Standalone Odin packages for strict TOML 1.1 documents and allocation-free temporal values.

This repository is being implemented in dependency-ordered tickets. Public declarations are frozen; procedures whose implementation tickets have not landed yet intentionally call `unimplemented` if executed.

## Packages

- Repository root: package `toml`
- [`temporal/`](temporal): package `temporal`

`toml` imports `temporal`; `temporal` does not import `toml`. External consumers can use a relative import or map the repository into an Odin collection.

## Semantic ownership

Successful parse and clone calls return owners. `get` returns only a borrowed pointer: do not destroy it, and do not retain it across structural mutation or destruction of its containing table. A successful `clone_value` creates an independent standalone owner.

`set` borrows and validates its key and value, deep-clones committed ownership through the target table's retained allocator, preserves replacement position, and appends new keys. It rejects zero tables and malformed text, temporals, containers, duplicates, cycles, ownership aliases, allocator mismatches, and local paths deeper than 256 without changing the table. `remove` requires a valid acyclic, exclusively owned, allocator-consistent table; it destroys the removed owner and stably compacts the table, so removing and reinserting a key appends it. Any successful structural mutation invalidates all value pointers borrowed from that table.

- Release a `Document` with `destroy_document`.
- Release a standalone cloned `Value` with `destroy_value` and the same allocator used to clone it.
- Both destroy operations zero the supplied owner and are idempotent.
- With an external-lifetime allocator, destruction ends logical ownership; reclaim physical storage through that allocator's lifetime.

The executable [`examples/semantic_lifecycle`](examples/semantic_lifecycle/main.odin) demonstrates an initialized empty document and the difference between a borrowed `get` result and an owned deep clone.

## Reproducible checks

The supported compiler is pinned in [`toolchain/odin.lock`](toolchain/odin.lock). With that compiler on `PATH`:

```sh
scripts/check.sh
```

The command captures `odin version` and `odin report` in `build/reports/compiler.txt`, checks the frozen generated API snapshots, rejects runtime oracle dependencies, and compiles both external consumers in normal and `-o:speed` modes.

RTTI-disabled compilation currently exposes a pinned-compiler incompatibility rather than a package workaround:

```sh
scripts/probe_no_rtti.sh
```

See [`design-reviews/001-reference-odin-no-rtti.md`](design-reviews/001-reference-odin-no-rtti.md). Typed binding requires RTTI by contract.

## Test-only dependency pins

- `toml-lang/toml-test` v2.2.0 at `ce08da1ddb075d1c7596d663c7fcba9a2ae02c5c`, TOML version `1.1.0`: [`tests/corpus/toml-test.lock`](tests/corpus/toml-test.lock)
- Ryu at `4c0618b0e44f7ef027ebae05d2cc7812048f7c8f`: [`tests/oracle/ryu.lock`](tests/oracle/ryu.lock)

Their upstream licenses are retained beside the locks. Prepare exact test-only source checkouts and build the official corpus runner with:

```sh
scripts/prepare_test_dependencies.sh
```

All generated sources and tools stay under ignored `build/`. Neither source is vendored, imported, linked, or otherwise used by the runtime packages.

# Consumer guide

The root `toml` package implements strict TOML 1.1 semantic documents and typed binding. Its public values make ownership explicit; ordinary Odin assignment does not duplicate an owner.

## Parse, borrow, mutate, and destroy

`parse_string` and `parse_bytes` borrow their input only for the call. On success they return a `Document` that owns every allocation reachable from `root` through the selected allocator. Release that owner with `destroy_document`; the operation ends logical ownership, zeros the document, and is idempotent.

`get` returns a borrowed `^Value`. Never pass that pointer to `destroy_value`. It remains valid only until its table is structurally mutated or destroyed. Any successful `set` or `remove` invalidates every value pointer borrowed from that table, including pointers to entries other than the changed entry. Failed mutations do not change the table or invalidate borrows.

`set` borrows its key and source value for the call and deep-clones committed ownership with the target table's retained allocator. `remove` destroys the removed owner. Use `clone_value` when a borrowed value must outlive its source or a mutation; the returned standalone owner is independent and must be released with `destroy_value` and the same allocator used for the clone.

[`examples/semantic_lifecycle`](../examples/semantic_lifecycle/main.odin) shows owner initialization, borrowed lookup, clone, and destruction. [`examples/consumer_contract`](../examples/consumer_contract/main.odin) executes mutation and proves that an earlier clone remains independent.

## Allocators and cleanup

Every allocating entry point accepts an allocator. A document or cloned semantic value is uniform-allocation: every reachable owner uses the selected allocator. Allocated canonical output from `unparse` is a `string`; output from `marshal` is `[]byte`. The caller owns either successful result and deletes it with the selected allocator. Writer forms return no output allocation to the caller and never transfer ownership of the writer.

Two allocator lifetime modes are supported:

- **Individually freeing allocator:** recursively clean typed results child-before-container. Delete and zero strings; clean slice or dynamic-array elements before deleting and zeroing the container; clean owned map keys and values before deleting and zeroing the map; clean a pointee before freeing and niling it; clean an optional union's active alternative before setting it to nil. Structs and fixed arrays recursively visit owning fields or elements.
- **External-lifetime allocator:** zero or discard every installed owning slot to end access, then reclaim the allocator's complete lifetime, for example by destroying or resetting its arena. Do not issue unsupported individual frees merely to imitate the first mode.

Typed unmarshal preflights the complete binding before installation. A preflight error leaves the destination unchanged. An allocation error during installation may leave earlier ownership-safe units installed; those units become caller-owned immediately, even though the call returned an error. Start projected destinations wholly zero where mechanical cleanup is desired, and apply the recursive rules above after both success and partial failure. Missing and `toml:"-"` fields are untouched and may require application-specific provenance-aware cleanup. There is intentionally no generic typed destructor.

[`examples/typed_unmarshal_cleanup`](../examples/typed_unmarshal_cleanup/main.odin) executes complete and fail-at-every-allocation cleanup with both an individually freeing allocator and an external-lifetime arena.

## Canonical output and typed binding

`unparse` and `unparse_to_writer` emit the same all-inline canonical profile. `marshal` and `marshal_to_writer` use that same emitter after complete typed preflight. Semantic insertion order and struct declaration order are retained; map keys are converted and sorted deterministically. Writer calls begin only after preflight succeeds.

`unmarshal` and `unmarshal_string` strictly parse before typed preflight and installation. They never install aliases into the input. Owning destination slots matched by the projected TOML shape must be zero; allocation-free scalar defaults are allowed.

[`examples/consumer_contract`](../examples/consumer_contract/main.odin) compares allocated and writer semantic output byte-for-byte, marshals and unmarshals a typed value, and verifies that parse and typed-marshal errors return no output owner.

## Codec registries

A `Codec_Registry` is caller-owned and per-call. Initialize it, register exact source and destination `typeid` callbacks, pass its pointer through options, then destroy it. The registry owns only its lookup maps; callback code and `user_data` remain application-owned and must outlive every borrowing call. There is no package-global registry.

Complete registration before sharing a registry. Concurrent read-only lookup through a frozen registry is supported. The caller must synchronize mutable state reached through `user_data`. Registration or destruction while any TOML operation or other reader is using the registry violates the contract.

Marshal callbacks return complete allocator-owned semantic values, never raw TOML. Unmarshal callbacks receive an exact clean destination slot and must restore that entire slot to zero before returning an error. Callback sources, destinations, semantic values, and reachable pointers are borrowed only for the callback. Do not retain them, mutate callback sources, or re-enter typed TOML operations from an active callback.

The typed round trip in [`examples/consumer_contract`](../examples/consumer_contract/main.odin) registers directionally paired callbacks and destroys the caller-owned registry.

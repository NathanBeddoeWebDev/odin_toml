# Choose the custom-codec registry model

Type: grilling
Status: resolved
Blocked by: 01, 05, 08, 11

## Question

Should TOML per-`typeid` marshalers and unmarshalers use JSON-compatible package-global registration, option-supplied registries, or both; and what registration, precedence, concurrency, recursion, allocator, error, and lifetime rules make the mechanism predictable?

## Answer

Use one caller-owned, option-supplied `Codec_Registry`; provide **no** package-global codec state, setter, registration pathway, or fallback registry. The registry has independent exact-`typeid` marshaler and unmarshaler entries, so a type may support either direction or both. This preserves per-call composition, parallel-test isolation, and library concurrency, unlike the mutable process-global JSON precedent.

A nil registry pointer means that no custom codecs are selected. A non-nil registry is borrowed for the complete marshal or unmarshal call. `Marshal_Options` and `Unmarshal_Options` therefore gain the same field:

```odin
Marshal_Options :: struct {
    max_depth: int, // 0 selects 128
    codecs:    ^Codec_Registry,
}

Unmarshal_Options :: struct {
    max_depth:             int, // 0 selects 128
    reject_unknown_fields: bool,
    codecs:                ^Codec_Registry,
}
```

The field configures typed binding only. `unparse` and `unparse_to_writer` accept `Marshal_Options` for their common depth policy, but ignore `codecs` completely: a semantic `Document` already contains TOML values, not application-defined values to bind.

### Registry ownership and registration

`Codec_Registry` is an explicit lifecycle owner for its two lookup maps and records the allocator with which those maps were initialized. Its conceptual public surface is:

```odin
Codec_Registry :: struct { /* registry-owned storage and allocator metadata */ }

Codec_Marshaler :: struct {
    procedure: Codec_Marshal_Proc,
    user_data: rawptr,
}

Codec_Unmarshaler :: struct {
    procedure: Codec_Unmarshal_Proc,
    user_data: rawptr,
}

init_codec_registry :: proc(
    allocator := context.allocator,
    loc := #caller_location,
) -> (Codec_Registry, Codec_Registry_Error)

destroy_codec_registry :: proc(registry: ^Codec_Registry, loc := #caller_location)

register_marshaler :: proc(
    registry: ^Codec_Registry,
    id: typeid,
    marshaler: Codec_Marshaler,
    loc := #caller_location,
) -> Codec_Registry_Error

register_unmarshaler :: proc(
    registry: ^Codec_Registry,
    id: typeid,
    unmarshaler: Codec_Unmarshaler,
    loc := #caller_location,
) -> Codec_Registry_Error
```

The registry maps are keyed by the exact, comparable Odin `typeid`. Initialization, registration, and destruction use only the registry's recorded allocator; registration never falls back to the ambient allocator. `init_codec_registry` rejects a nil allocator procedure. Registration rejects a nil or uninitialized registry, a nil callback, and a nil/invalid type id; it propagates the exact `runtime.Allocator_Error` from map growth. A second registration for the same direction and type is a `Duplicate_Codec` error. There is deliberately no replacement or unregister operation. Registering a marshaler and an unmarshaler for the same type is legal because their maps are independent.

`destroy_codec_registry` destroys only the map storage and zeros the registry; it is idempotent. It neither calls a callback nor frees `user_data`. Callback procedure code and `user_data` are always application-owned borrowed state. `user_data` may be nil and, when non-nil, must remain valid for every call that borrows the registry.

The registry is mutable only while no TOML operation borrows it. The package adds no locks and makes no concurrent-registration promise. Once initialized and no longer being registered into or destroyed, the same registry may be read concurrently by multiple marshal and unmarshal calls. The caller must synchronize any mutable callback state in `user_data`; registry read safety does not make arbitrary user state thread-safe. Destroying or registering into a registry while a call uses it is a caller contract violation.

### Codec callback boundary

A codec is a conversion at the typed-binding boundary, not a way to write or parse arbitrary TOML syntax. The conceptual callback signatures are:

```odin
Codec_Callback_Failure :: struct {
    code: u32, // codec-defined and nonzero
}

Codec_Callback_Error :: union {
    Codec_Callback_Failure,
    runtime.Allocator_Error,
}

Codec_Marshal_Proc :: #type proc(
    source:    any,
    user_data: rawptr,
    allocator: mem.Allocator,
    loc:       runtime.Source_Code_Location,
) -> (Value, Codec_Callback_Error)

Codec_Unmarshal_Proc :: #type proc(
    source:      ^Value,
    destination: any,
    user_data:   rawptr,
    allocator:   mem.Allocator,
    loc:         runtime.Source_Code_Location,
) -> Codec_Callback_Error
```

A nil `Codec_Callback_Error` means success. A codec-defined rejection uses a nonzero `Codec_Callback_Failure.code`; it cannot return a package `Marshal_Error` or `Unmarshal_Error`, textual message, source slice, or caller-owned path. This keeps every public error allocation-free and lets the package attach the trustworthy current path and, for unmarshal, source range. A callback allocation failure uses the exact `runtime.Allocator_Error` it received from work done with the supplied allocator.

The `source` passed to a marshaler is a borrowed `any` whose dynamic type is the exact registered type. The `destination` passed to an unmarshaler is a writable, pointer-backed `any` whose dynamic type is the exact registered destination type; its `.data` addresses that destination storage, as in the installed JSON custom-unmarshal precedent. A codec may access it only as the type for which it was registered. Neither callback may retain its `any`, its data pointer, the supplied `^Value`, or any borrow reached through those values after it returns. Neither may mutate the marshaling source or the parsed semantic source value.

There is no generic reflected assignment API and no codec-controlled parser or writer. A custom marshaler returns a semantic `Value`; it must allocate every escaping key, string, array, and table with the supplied allocator, establish the normal initialized-container and exclusive-ownership invariants, and transfer that temporary owner to TOML only on success. It must not return source aliases, registry-state aliases, a `Document`, or a partial result on error. The package validates the returned value—relative to the current path and remaining depth—and emits it with the normal canonical encoder. This prevents a codec from bypassing TOML validity, deterministic output, source preflight, or writer error handling.

The package retains every successful codec-produced value through the complete encode preflight and emission plan, then destroys it with the supplied allocator on every return path. It destroys all such temporary values on a later preflight, output-allocation, or writer error as well. A codec cleans every temporary it has not returned before returning an error. Thus no codec-produced owner escapes from `marshal` except through the allocated TOML bytes, and no codec-produced owner escapes from writer forms at all.

A custom unmarshaler receives a borrowed parsed semantic value and a destination slot that has been established as completely zero/clean before invocation. This stronger rule applies even when the registered type is allocation-free; it avoids an opaque codec overwriting storage whose ownership TOML cannot infer. On success, every allocation it installs belongs immediately to the application destination and uses the supplied allocator. The application must clean that successful custom value according to its own type's ownership contract, just as it must clean other installed typed values.

A custom unmarshaler is transactional for its own supplied slot: before it returns any error, it must release every allocation it installed for that attempt and restore the slot to its exact zero state. It must validate any codec-specific source rule and target precondition before committing a value. This is intentionally stricter than generic typed installation because TOML cannot synthesize a safe destructor for an arbitrary registered type. It does not make the whole `unmarshal` call transactional: commit units before the codec's path remain installed and caller-owned, while the failing codec's own slot remains clean. Package-owned parse trees, reflection scratch, and uninstalled work are still cleaned by the package on every error.

For a codec nested inside a map value, the callback receives its exact final slot in preallocated map storage. A generic map pair remains staged and removable until complete unless a nested custom unmarshaler succeeds. That first opaque success commits the containing entry to the application; a later failure may leave the entry recursively cleanable and partially installed, with the currently failing callback slot exact zero. This explicit refinement preserves immediate application ownership without adding a custom destructor or invoking a callback twice. [Design review 002](../../../design-reviews/002-custom-unmarshal-map-commit-boundary.md) records the approved commit boundary.

### Selection, invocation, depth, and recursion

Codec selection is exact and directional. At each typed-binding node, TOML looks up the registry entry for the node's exact `typeid` before generic named-type handling, scalar conversion, temporal terminal handling, or unsupported-kind rejection. A matching marshaler is used only for marshal; a matching unmarshaler is used only for unmarshal. A missing entry in one direction falls through to the normal generic rule in that direction.

For marshal, an outer `any` is first unwrapped to its dynamic value because `any` is not itself a TOML representation. Lookup then occurs on the presented exact type. Consequently a codec may target an exact pointer or optional-union wrapper; if no wrapper codec is registered, generic wrapper handling exposes the contained value and lookup occurs again at that child node. This permits both a codec for `^T` and a distinct codec for `T` without making one silently shadow the other. For unmarshal, a destination of `any` remains unsupported and is never made valid by a codec; all other exact destination types, including otherwise unsupported types, may be registered. The root rules from issue 11 remain in force after lookup: a custom root marshaler's returned value must be a `Table`, and a custom root unmarshaler receives the parsed root table.

Map keys are not typed-value binding nodes and never consult the registry. The generic map-key rule remains exactly `string` or a named/distinct string type; custom conversion of TOML keys is excluded. This keeps map-key validation, UTF-8 ordering, converted-key collision detection, destination key ownership, and canonical map traversal entirely package-controlled.

A matched codec is invoked exactly once for its encountered node during the deterministic traversal: struct declaration order, array index order, and sorted converted-map-key order for marshal; semantic table insertion and array index order for unmarshal. `omitempty` is applied before marshaler lookup, so an omitted field does not invoke its codec or inspect its value. Marshaler results are cached in the preflight plan; callbacks are never called again during writer emission or exact-size allocated-result production. There is no memoization across separate source occurrences, even if application pointers alias, because typed marshal encodes each occurrence by value.

Returned codec values participate in the same maximum-depth, cycle, alias, UTF-8, temporal, duplicate-key, size, and canonical-order validation as ordinary semantic values. A cycle or alias inside the returned `Value` is rejected by package validation. A codec that itself traverses an application graph is responsible for detecting cycles in that graph before returning a semantic value.

Callbacks have no recursive typed-binding helper. They must not call `toml.marshal`, `toml.marshal_to_writer`, `toml.unmarshal`, or `toml.unmarshal_string` directly or indirectly as part of the same codec invocation. Such re-entry would create an unbounded application-controlled recursion outside the operation's depth and diagnostic stack. A codec composes by constructing or consuming the supplied semantic `Value` itself. It may use semantic-value clone/destruction and `temporal` operations under their normal ownership contracts. Parsing, unparsing, or other unrelated TOML operations are not callback composition mechanisms and do not inherit the active binding state.

### Error placement and failure precedence

`Codec_Registry_Error` is an allocation-free union of its registry-data alternatives and the exact `runtime.Allocator_Error`. It distinguishes at least invalid allocator, invalid/uninitialized registry, invalid type id, nil callback, and duplicate codec. Registry errors are returned by lifecycle or registration operations, never deferred to marshal/unmarshal.

A non-nil but invalid registry supplied through options is a configuration error; a nil registry is valid and simply disables custom lookup. Configuration precedence is explicit: marshal checks nil allocator, then (for a writer form) nil options pointer, invalid `max_depth`, and invalid non-nil registry before source traversal or writer output. Unmarshal checks nil allocator, invalid `max_depth`, nil destination, and then invalid non-nil registry before strict parsing. Thus the established nil-destination error wins when it coincides with an invalid registry. No registry check occurs during reflection planning, callback invocation, or writer output.

During marshal preflight, a codec-defined callback failure stops traversal at that canonical path and becomes a `Marshal_Codec_Error` carrying the registered type id and callback code. An allocator error returned by the codec propagates as the exact allocator-error alternative rather than being collapsed into a codec failure. If a successful callback returns an invalid semantic value, normal package data/limit validation reports that value's first error, not a fabricated callback rejection. No writer call has occurred before any of these failures.

Generic binding errors still use issue 11's deterministic traversal order. Codec lookup replaces generic processing only at the matched node, so a codec cannot suppress an earlier tag, field-plan, map-key, configuration, depth, or other canonical-path error. Codec-specific unmarshal validation necessarily occurs during installation, since TOML cannot preflight an opaque callback's semantics. Its `Unmarshal_Codec_Error` carries the exact registered type id, callback code, the package path, and the source range of the bound semantic value. A callback allocator error propagates exactly. The current callback slot is clean on failure, but already committed earlier installation units remain caller-owned under issue 08; generic preflight failures before installation still leave the complete destination unchanged.

The codec mechanism therefore preserves the package-wide guarantees: no mutable global state, no raw TOML output escape hatch, strict parsing before typed decode, allocation-free diagnostics, deterministic marshaling, no writer output before complete marshal preflight, exact allocator propagation, and explicit caller ownership at every transfer boundary.

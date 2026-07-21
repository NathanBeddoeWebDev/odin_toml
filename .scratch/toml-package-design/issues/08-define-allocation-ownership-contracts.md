# Define allocation, ownership, and failure-cleanup contracts

Type: grilling
Status: resolved
Blocked by: 01, 05, 07

## Question

For every public parsing, cloning, mutation, encoding, writer, and typed-binding operation, which allocator owns each allocation, when is ownership transferred, what invalidates borrowed views, which destroy operation releases it, and what cleanup and partial-result guarantees apply on every error path?

## Answer

Use explicit, exclusive ownership throughout. An allocator physically owns its allocations; an owning value is the program value responsible for eventually releasing those allocations through that allocator. Passing an owner by ordinary Odin assignment does not duplicate or transfer ownership: it creates a shallow borrowed alias. Only the successful returns and mutation commits named below transfer ownership. Only deep clone creates another owner.

### Owning document and allocator invariant

Add allocator bookkeeping to the physical document representation:

```odin
Document :: struct {
    root:      Table,
    allocator: mem.Allocator,
}
```

The allocator field is lifecycle metadata, not TOML semantics. Every successful parse or document clone initializes every reachable table and array, including empty containers, and allocates all reachable non-empty keys and strings with `Document.allocator`. Package-produced documents are therefore uniform-allocation, acyclic, exclusively owned trees. A zero `Document` is non-owning and is not a successfully initialized empty document.

The parser, clone operations, allocated encoders, typed unmarshal, writer operations that need scratch storage, and every other owner-creating public call select an allocator explicitly, defaulting to `context.allocator`, and forward `loc := #caller_location`. Reject an allocator with a nil procedure before allocating; arbitrary custom-allocator state cannot be prevalidated, so every allocation checks both its returned storage and `Allocator_Error`. Options, codec registries, callback state, input text, writers, and source application values are borrowed only for the duration of the call, except for the narrowly specified typed diagnostic-path borrows below or unless a later codec contract explicitly says otherwise.

Owner-bound table mutation is the deliberate exception to issue 05's per-call allocator rule. `Table` is a dynamic array and retains its allocator. `set` and `remove` use `table.allocator`, so a caller cannot accidentally mix allocators. Package-produced empty tables are initialized and have an allocator; mutation rejects a zero/uninitialized caller-created table. All sanctioned descendants of a document use the same allocator as the document.

### Destruction and cloning

Expose these canonical lifecycle families, with the final error declarations following the package-wide error design:

```odin
clone_document   :: proc(doc: ^Document, allocator := context.allocator, loc := #caller_location) -> (Document, Clone_Error)
destroy_document :: proc(doc: ^Document, loc := #caller_location)

clone_value   :: proc(value: ^Value, allocator := context.allocator, loc := #caller_location) -> (Value, Clone_Error)
destroy_value :: proc(value: ^Value, allocator: mem.Allocator, loc := #caller_location)
```

Inputs to clone are borrowed and unchanged. Successful clone is deep, preserves table insertion and array order, has no aliases to the source, and transfers one new owner to the caller. `clone_document` records the selected allocator. A standalone cloned `Value` has no allocator metadata, so its caller must retain the selected allocator and pass it to `destroy_value`. Both destroy operations recursively invalidate all borrows, release as described below, and zero the supplied owner so repeated destruction is a no-op. `destroy_document` uses the document's stored allocator and accepts no replacement allocator.

Clone validates while copying. It rejects invalid UTF-8 and temporal values, duplicate keys, invalid union/container states, excessive nesting, cycles, and ownership-invalid repeated container or non-empty string aliases as far as their backing identities are detectable. It returns a data-or-allocation `Clone_Error`. On any error it releases all partial output and scratch state and returns a zero result; the source is untouched.

Destruction supports individually freed and externally reclaimed allocators without requiring TOML-specific registration. An allocator used for individual destruction must support freeing its allocations in arbitrary order; advertising `.Free` alone does not make a LIFO stack allocator suitable, because recursive destruction is not guaranteed to reproduce allocation order. The package uses allocator feature information when available; if reported capabilities omit `.Free`, destruction performs only logical zeroing. When feature reporting is unavailable, it attempts normal individual release; `.Mode_Not_Implemented` before any release succeeds stops individual release and causes logical destruction and zeroing only. Neither case proves that bulk reclamation exists: the caller remains responsible for whatever external lifetime the allocator requires, and that lifetime must cover every use of the TOML owner. The package never calls `.Free_All`, because the allocator may contain unrelated allocations. A core arena is physically reclaimed when its caller resets or destroys it. Once individual release succeeds, the allocator must support arbitrary-order release consistently for the tree; any later allocator error, invalid pointer, out-of-order-only allocator, or mixed-allocator tree is a caller/allocator contract violation rather than a recoverable package error. Destruction remains a conventional result-less cleanup operation.

### Semantic-document mutation and borrows

Use the direct operation names chosen in issue 07. Their ownership-bearing shapes are:

```odin
get    :: proc(table: ^Table, key: string) -> (^Value, bool)
set    :: proc(table: ^Table, key: string, value: ^Value, loc := #caller_location) -> Mutation_Error
remove :: proc(table: ^Table, key: string, loc := #caller_location) -> bool
```

`get` does not allocate or transfer ownership. It returns a borrowed pointer to the matching value. The pointer must not be destroyed. Any sanctioned or direct structural mutation of that table—including replacement, append/resizing, removal/compaction, entry assignment, key mutation, or destruction—invalidates all pointers borrowed from that table, even when storage happened not to move. Mutation of a descendant does not invalidate the pointer to its containing `Value`, but resizing or destroying that descendant invalidates borrows into it. Document destruction invalidates every borrow into the document.

`set` borrows `key` and `value` and deep-clones what it stores with `table.allocator`; the caller retains the inputs. For an existing key, it validates and clones the replacement before committing, preserves the existing owned key and entry position, then destroys the old value. For an absent key, it validates and clones both key and value before append. A self-reference or a value borrowed from the same or another document is therefore safe to pass. Any data, depth, or allocation failure cleans temporary clones and leaves the table semantically and physically unchanged. Success transfers the clones to the table.

`remove` allocates nothing, destroys the removed owned key and value with `table.allocator`, performs stable compaction, and returns whether an entry existed. It never transfers the removed value. A caller needing it must clone it successfully before removal.

Do not add array mutation wrappers. Arrays remain transparent dynamic arrays. Safe direct mutation requires callers to clone inserted values with `array.allocator`, destroy replaced or removed values with that same allocator, clean an uncommitted clone after append failure, and treat a successfully appended or assigned clone as transferred to the array. Direct shallow insertion, duplicate ownership, mixed allocators, or failure to destroy displaced values violates the ownership contract. Array resize, assignment, removal, and compaction invalidate affected element borrows; conservatively, callers should discard all element pointers after structural mutation.

### Parsing

`parse_bytes` and `parse_string` borrow the complete input only for the call and never expose it as document or error storage. Every returned key and string is independently owned, including decoded escaped text. Success transfers one `Document` owner to the caller. After either success or failure, the input may be changed or released immediately. Diagnostics retain only numeric source offsets/ranges and positions, not source slices; rendering an excerpt later requires the caller to retain and pair the original input itself.

Parsing is transactional. Syntax, semantic, UTF-8, depth, or allocation failure destroys the entire partial tree and all parser scratch state and returns a zero `Document`; no partial document ownership escapes. Under a bulk allocator, released scratch becomes unreachable but is physically reclaimed with that allocator's bulk lifetime.

### Semantic and typed encoding

`unparse` borrows its document and returns a `string`; `marshal` borrows its `any` source and returns a `[]byte`. A successful empty output has nil backing storage, owns no allocation, and requires no deletion. A successful non-empty output owns one exact-length backing allocation—its allocation size equals the returned length, never a hidden builder capacity. Producing that exact-size result, including any final shrink or copy, is part of the fallible operation. When the allocator supports arbitrary-order individual release, the caller releases a non-empty result with `delete(result, allocator)`. With an externally reclaimed allocator such as an arena, the caller instead discards the result reference and reclaims storage through the allocator's external lifetime; it must not call unsupported individual deletion. On validation, codec, allocation, final-sizing, or encoding failure, the allocated-return procedures logically destroy their builders and scratch state and return a nil-backed empty output; individually releasable storage is freed immediately, while externally owned storage remains until its allocator lifetime reclaims it. No partial output ownership escapes. They do not mutate their source.

`unparse_to_writer` and `marshal_to_writer` borrow the writer, source, stable options pointer, codec registry, and callback state. They transfer no ownership to the package or writer. Deterministic sorting and other scratch allocations use the call's allocator and are released on every return, subject to that allocator's bulk-lifetime behavior. Writer output is non-transactional only after complete preflight succeeds: an `io.Error` after a write may leave an arbitrary already-written prefix, and the package neither rolls it back nor retries it. Data, allocation, and codec failures identified during preflight occur before the first writer call. The exact writer error is propagated.

Unparse, marshal, and clone validation use cycle/alias tracking and reject malformed caller-constructed trees rather than recursing indefinitely. Validation scratch never becomes part of the source or result.

### Typed unmarshal

`unmarshal` and `unmarshal_string` borrow input and the destination pointer but mutate the destination in place. Input text is never installed by alias: strings, slices, dynamic arrays, maps, pointers, and any other package-created destination storage use the selected allocator. On successful installation into a field or container, ownership transfers immediately to the destination. Maps and dynamic arrays retain their allocator; callers must separately remember the allocator for strings, slices, and pointers.

No generic typed-destination destructor is provided: reflection cannot safely infer application ownership or custom-codec cleanup. With an arbitrary-order individually freeing allocator, the caller must recursively clean installed owning children before releasing each containing allocation with the original allocator, and must zero every cleaned owning slot afterward. In particular, delete and zero owned strings; recursively clean slice elements, delete the slice with the allocator, then zero it; recursively clean dynamic-array elements, delete the dynamic array through its retained allocator, then zero it; clean owned map keys and values, delete the map, then zero it; recursively clean a pointer's pointee, free the pointer, then nil it; and recursively visit and zero owning fields or active alternatives in structs, arrays, and unions. With an externally reclaimed allocator, the caller does not invoke unsupported individual deletion: it zeroes every owning slot or the complete destination and later reclaims storage through the allocator's external lifetime. Issue 11 must give an exact cleanup table for every generically supported destination kind, while issue 12 must define codec-specific cleanup responsibility.

Unmarshal never frees storage that was already present in the destination. Before allowing a field to be overwritten, callers must both clean and zero any resource-owning value already there; a zeroed destination is the safe default, while allocation-free scalar defaults are permitted. A failure may leave any earlier fields populated. Every installed allocation remains caller-owned and must be cleaned and zeroed through the partially populated destination using the same allocator-specific recursive rules. Every package-owned allocation not yet installed, plus parser/reflection scratch, is logically cleaned before return; storage is individually freed or left to its external allocator lifetime as above. This is the only public decoding workflow that intentionally returns partial application state.

Custom unmarshaler callbacks may likewise leave their explicitly supplied target partially changed; their exact commit unit and allocator parameter belong to issue 12, but they may not weaken these rules for package-owned temporary storage. Callback registry entries and user data remain caller-owned and are only borrowed by the operation.

### Error and path lifetimes

All public error values are allocation-free and require no destructor. Inline bounded storage, tied to the package's maximum nesting contract, holds path bookkeeping. A diagnostic path produced while inspecting a semantic document may borrow segment strings from that document and is invalidated by mutation or destruction affecting them. A marshal path may borrow RTTI names, which have process lifetime, or strings from the caller's source value; source-backed segments remain valid only until the relevant source string, map key, container, or enclosing value is mutated, moved, cleaned, or destroyed. An unmarshal path may borrow RTTI names or strings already installed in the destination; destination-backed segments remain valid only until the relevant destination field, key, container, or enclosing value is mutated, moved, cleaned, overwritten, or destroyed. Parse and unmarshal diagnostics never borrow source-input slices; when unmarshal cannot safely borrow a decoded semantic key from stable installed destination storage, it reports numeric source range and position instead of allocating a path solely for the error. The downstream error tickets define the exact inline representation, source-range form, and explicit truncation marker.

### Failure-guarantee summary

| Operation | Success ownership | Error guarantee |
| --- | --- | --- |
| `parse_*` | caller owns returned `Document` | zero document; all partial state cleaned |
| `clone_document` / `clone_value` | caller owns deep clone | zero result; source unchanged; partial clone cleaned |
| `get` | borrowed `^Value` only | absence only; no allocation or mutation |
| `set` | table owns internal clones | table unchanged; temporary clones cleaned |
| `remove` | removed subtree destroyed | no fallible package result under a valid allocator contract |
| `unparse` / `marshal` | caller owns returned text/bytes | empty output; builder and scratch cleaned |
| writer operations | writer retains any emitted prefix | no rollback; package scratch cleaned; exact error propagated |
| `unmarshal*` | installed allocations belong to destination | destination may be partial; installed state remains caller-owned; uninstalled temporary state cleaned |
| destroy operations | ownership ends and argument is zeroed | allocator-contract violations are programming errors |

All cleanup and leak tests must cover the default heap, a tracking allocator, forced allocation failures at successive allocation sites, and a bulk-lifetime arena. Tests must verify transactional operations return zero results, typed unmarshal preserves cleanable partial state, writer failures retain only writer-owned prefixes, set is unchanged on failure, borrowed pointers are treated as invalid after mutation, and no procedure accidentally falls back to the ambient allocator.

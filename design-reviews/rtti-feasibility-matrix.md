# Reference-Odin typed-binding feasibility matrix

Status: checked; semantic `-no-rtti` compilation remains blocked by [design review 001](001-reference-odin-no-rtti.md)

Compiler: Odin `dev-2026-07:2c25fb924` (`2c25fb92420bfa31da62e2194b0cc2cb8bd54cf8`)

The executable evidence is `tests/rtti_probe/main.odin`. `scripts/probe_rtti.sh` runs it in minimal and optimized modes after verifying the compiler pin. “Proven” means the pinned compiler both compiled and ran the named probe; source links identify the exact mechanism that the later binder may use. This gate approves mechanisms, not implementations of tickets 19–24.

## Checked matrix

| Approved typed feature | Pinned mechanism | Probe evidence | Result |
| --- | --- | --- | --- |
| Exact codec lookup before generic handling | Comparable `typeid` keys in `map[typeid]…`; distinct and base IDs differ | `probe_exact_type_identity` performs exact hit and base-type miss | Proven |
| Named/distinct generic fallback without losing codec identity | `reflect.type_kind`, `underlying_type_kind`, and `any_base` preserve the data address while deliberately replacing only the ID | `probe_exact_type_identity` checks distinct string and integer IDs, alias identity, kind, base ID, and address | Proven |
| Closed scalar categories (bool, integer, float, string) | RTTI distinguishes exact IDs and underlying `Type_Kind`; destination-backed `any` supports exact pointer type switches | `probe_exact_type_identity` checks all four underlying categories; `probe_struct_reflection_and_destination_any` performs destination assignment | Proven |
| Exact temporal-only matching | Direct `typeid` equality is available before named-type fallback | `probe_exact_type_identity` distinguishes `temporal.Local_Date` from a layout-equivalent struct | Proven |
| Struct declaration-order projection | `reflect.struct_fields_zipped` returns compiler RTTI arrays in declaration order | `probe_struct_reflection_and_destination_any` checks `first`, anonymous wrapper, `last` order | Proven |
| Complete field tags and TOML tag lookup | Each `Struct_Field` exposes its raw `tag`; `struct_tag_lookup` distinguishes absent from explicitly present empty values | Same probe checks absent wrapper tag and exact TOML tag values | Proven |
| Anonymous `using _: Struct` flattening | `Struct_Field.name == "_"`, `is_using`, nested field RTTI, and byte offsets identify the wrapper and children | Same probe checks wrapper metadata and nested tagged child | Proven |
| Writable reflected struct destinations | `struct_field_value` returns an `any` whose data pointer addresses destination storage | Same probe assigns ordinary and flattened fields through reflected `any` values and observes destination mutation | Proven |
| Field validation even when absent | Every selected field exposes exact `^Type_Info` independently of a source value | Struct and nested-field metadata checks | Proven |
| Fixed and enumerated array shape checks | Array RTTI exposes element ID, element size, and count; reflected iteration preserves exact element ID and index | `probe_binding_type_metadata` checks exact fixed-array count/element ID and runs `reflect.iterate_array` | Proven |
| Slice installation | `Type_Info_Slice` exposes exact element metadata; `mem.Raw_Slice` permits destination descriptor installation from selected-allocator storage | `probe_allocator_controlled_container_installation` allocates through the observed allocator, installs a reflected `Raw_Slice`, reads both elements, and explicitly frees with the selected allocator | Proven |
| Dynamic-array installation and retained allocator | `Type_Info_Dynamic_Array` plus `mem.Raw_Dynamic_Array` expose element metadata and descriptor fields including allocator | `probe_allocator_controlled_container_installation` installs reflected storage, populates it, and frees it through the retained observed allocator while ambient allocation is rejected | Proven |
| String-keyed map eligibility and exact value type | `Type_Info_Map` exposes exact key/value `Type_Info` and runtime `Map_Info` | `probe_binding_type_metadata` checks distinct key/value IDs | Proven |
| Allocator-controlled map installation | Reflected destination data is a `mem.Raw_Map`; setting its allocator before `runtime.__dynamic_map_set_without_hash` controls map allocation | `probe_allocator_controlled_container_installation` installs a reflected map, reads the entry, and observes only the selected allocator | Proven |
| Deterministic map traversal input | `reflect.iterate_map` exposes exact key/value `any` values; package sorting can occur before value traversal | `probe_allocator_controlled_container_installation` iterates the reflected installed map and checks exact key/value IDs and contents | Proven |
| Ordinary pointer type and pointee access | `Type_Info_Pointer.elem`, destination-backed pointer storage, and `reflect.deref` expose the exact pointee | `probe_binding_type_metadata` and `probe_optional_union_and_wrapper_destinations` mutate the pointee through reflected wrapper access | Proven |
| Non-nil allocation for zero-size pointees | `size_of`, `align_of`, and explicit one-byte `mem.alloc_bytes(1, align, allocator)` provide an aligned sentinel | `probe_aligned_zero_size_pointee_installation` proves size zero, alignment 64, reflected pointer-slot installation, non-nil/aligned identity, recorded size/alignment, and matching release | Proven |
| Optional-union eligibility | `Type_Info_Union` exposes `variants` and `no_nil`; nil and active exact IDs are observable | `probe_optional_union_and_wrapper_destinations` checks one variant, available nil state, nil ID, and active ID | Proven |
| Optional-union destination activation/access | Exact `reflect.set_union_value` activation followed by `get_union_variant` returns destination-backed active storage | Same probe activates the sole alternative and mutates its field through reflected storage | Proven, with exact-type preconditions; unsafe APIs must stay encapsulated |
| Marshal `any` unwrapping | An `any` carries exact `data` and `id`; nil is distinguishable and nested exact lookup can repeat | Exact-ID/address checks and destination-backed `any` probe | Proven |
| `omitempty` type-aware checks | A reflected `any` dispatcher can combine exact RTTI kind with scalar, length, descriptor, and union inspection before traversal | `probe_omitempty_inputs` exercises `probe_is_empty` for false, integer and both float zero signs, empty string/fixed array/slice/initialized dynamic array/map, nil pointer/optional union/`any`; non-nil pointer and reflected `any` containing zero remain non-empty | Proven |
| Active recursion-cycle detection | Reflected pointer, slice, dynamic-array, and map identities are extractable from destination descriptors while traversal is active | `probe_cycle_identity` observes a pointer self-cycle, repeated acyclic pointer identity, and equal backing identities for aliased slices, dynamic arrays, and maps | Proven |
| Explicit rejection of unsupported kinds | Exact/underlying `Type_Kind` is the common discriminator for the closed unsupported-kind policy; no layout reinterpretation is needed | `probe_binding_type_metadata` runs named and direct unsupported discriminators (`Enum`, `Procedure`, `Type_Id`, `Any`); the pinned `Type_Kind`/`Type_Info` variants map every remaining issue-11 category | Proven mechanism; rejection behavior remains for typed-binding tickets |
| Checked destination size/alignment | `Type_Info.size`/`.align`, `reflect.size_of_typeid`, and `align_of_typeid` are available for checked arithmetic and allocation | Array/container metadata and aligned sentinel probes | Proven |
| Semantic consumer under `ODIN_NO_RTTI` | Required contract is that semantic import remains available while typed binding is unavailable | `scripts/probe_no_rtti.sh` checks `tests/consumer_semantic` on `freestanding_amd64_sysv`; compiler rejects frozen `any` declarations in `marshal.odin`/`codecs.odin` and imported core declarations | **Missing — design blocker 001** |
| Typed entry points under `ODIN_NO_RTTI` | Reference Odin's `-no-rtti` compiler diagnostic makes `any`/reflection unavailable | Same probe captures the exact unavailable boundary; changing declarations or package architecture would change the approved contract | Documented unavailable capability; no workaround approved |

## Gate decision

All RTTI-enabled mechanisms required by the approved typed-binding contract are feasible on the pinned compiler. The separate requirement that semantic workflows compile with RTTI disabled is not feasible with the frozen package interface: importing the semantic consumer still causes Reference Odin to type-check public typed declarations containing `any`, and Reference Odin also has unguarded `any` declarations in imported core packages.

This is a design-review blocker, not permission to omit typed declarations, split or conditionally narrow the public package, replace frozen types, or pretend RTTI is disabled through a project flag. Reflection-dependent implementation tickets remain blocked by this gate until design review 001 is resolved. Independent work, including the `temporal` package, is unaffected.

## Reproduction

```sh
scripts/probe_rtti.sh
scripts/probe_no_rtti.sh
scripts/check.sh
```

Generated reports are `build/reports/rtti-feasibility.txt` and `build/reports/no-rtti.txt`.

## Authoritative mechanism sources

- Live `core:reflect` API (generated with the Reference Odin version family): https://pkg.odin-lang.org/core/reflect/
- Pinned `core:reflect` implementation: https://github.com/odin-lang/Odin/blob/2c25fb92420bfa31da62e2194b0cc2cb8bd54cf8/core/reflect/reflect.odin
- Pinned runtime RTTI layouts: https://github.com/odin-lang/Odin/blob/2c25fb92420bfa31da62e2194b0cc2cb8bd54cf8/base/runtime/core.odin
- Pinned built-in container allocation/retained-allocator implementation: https://github.com/odin-lang/Odin/blob/2c25fb92420bfa31da62e2194b0cc2cb8bd54cf8/base/runtime/core_builtin.odin
- Live memory API: https://pkg.odin-lang.org/core/mem/
- Official reflection, tags, unions, and allocation overview: https://odin-lang.org/docs/overview/

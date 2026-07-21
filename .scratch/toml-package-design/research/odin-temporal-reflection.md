# Research: Odin temporal and reflection capabilities for TOML

## Summary

Installed-version sources support validated proleptic-Gregorian `datetime.Date`, `datetime.Time`, and `datetime.DateTime` values with nanosecond fields, and `time.Time` supports UTC instants only in 1677–2262. They do **not** provide a faithful built-in representation of all four TOML temporal kinds: offset date-time needs a TOML-specific fixed-offset representation, and exact fractional spelling/precision requires TOML metadata (or the original lexeme). Reflection can inspect fields/tags and expose writable field storage as `any`, but there is no general safe reflected-assignment/conversion procedure; assignment must be implemented by exact-type cases and carefully owned container/string operations.

The live package pages were generated with `dev-2026-07`; this matches the requested version family. The exact installed commit was supplied as `2c25fb924`; local source evidence below is pinned to that commit where possible. No source or tracker files were edited.

## Decision

1. Define four semantically distinct TOML value variants. Reuse the component layouts conceptually, but use TOML-owned types at least for `Offset_Date_Time`; use TOML wrappers for all four if lossless formatting/source precision is required.
2. Represent a fixed offset explicitly, preferably as sign/hour/minute (not only signed minutes if `-00:00` must remain distinguishable), and validate it in the TOML parser. Do not use `datetime.DateTime.tz` for a numeric TOML offset.
3. Store nanoseconds plus fractional digit count for canonical-with-precision formatting; retain the lexeme if digits beyond nanoseconds must round-trip exactly.
4. Implement reflection decoding around `typeid`-keyed custom converters, `reflect.Struct_Field`, tags, and destination-backed `any`. Do not treat `reflect.is_nil` as a semantic nil predicate and do not shallow-copy allocator-bearing values.

## Findings

1. **[high] The component package has useful types, but none is a complete TOML offset date-time.** `core:time/datetime` defines `Date {year:i64, month:i8, day:i8}`, `Time {hour:i8, minute:i8, second:i8, nano:i32}`, and `DateTime {using date:Date, using time:Time, tz:^TZ_Region}`. `TZ_Region` is a named timezone database structure with transition records, not a fixed numeric offset carried by TOML. Local date, local time, and local date-time can use these component shapes with `tz=nil`; offset date-time must carry its parsed numeric offset separately. Local evidence: `/Users/nathan/Developer/Odin/core/time/datetime/constants.odin:47-108`. [Official source](https://github.com/odin-lang/Odin/blob/2c25fb924/core/time/datetime/constants.odin#L47-L108) [Live `core:time` docs](https://pkg.odin-lang.org/core/time/)

2. **[high] `time.Time` is an instant, not a general TOML civil temporal type.** Its sole private field is Unix nanoseconds and its documented range is `1677-09-21` through `2262-04-11`; TOML four-digit civil years extend outside that interval. `time.components_to_time(...) -> (Time, bool)` and `compound_to_time(datetime.DateTime) -> (Time, bool)` validate and then reject instants outside the i64-nanosecond range. Use `time.Time` only as an optional derived UTC instant, never as the sole AST representation. Local evidence: `/Users/nathan/Developer/Odin/core/time/time.odin:5-58,954-1008`. [Official source](https://github.com/odin-lang/Odin/blob/2c25fb924/core/time/time.odin#L5-L58) [API](https://pkg.odin-lang.org/core/time/#components_to_time)

3. **[high] Component construction and validation APIs are concrete and allocation-free, with one boundary defect to guard locally.** Available signatures are:
   - `components_to_date :: proc "contextless" (#any_int year, #any_int month, #any_int day: i64) -> (date: Date, err: Error)`
   - `components_to_time :: proc "contextless" (#any_int hour, #any_int minute, #any_int second: i64, #any_int nanos := i64(0)) -> (time: Time, err: Error)`
   - `components_to_datetime :: proc "contextless" (...: i64, #any_int nanos := i64(0)) -> (datetime: DateTime, err: Error)`
   - `validate :: proc{validate_date, validate_year_month_day, validate_ordinal, validate_hour_minute_second, validate_time, validate_datetime}`.
   Validation correctly checks Gregorian month/day and `hour 0..23`, `minute/second 0..59`, but currently accepts `nano == 1_000_000_000` because it tests `nano > 1e9`, although valid nanoseconds must be `< 1e9`. TOML must enforce `0 <= nano < 1_000_000_000` itself. Local evidence: `/Users/nathan/Developer/Odin/core/time/datetime/datetime.odin:38-85`; `/Users/nathan/Developer/Odin/core/time/datetime/validation.odin:7-105`. [Official construction source](https://github.com/odin-lang/Odin/blob/2c25fb924/core/time/datetime/datetime.odin#L38-L85) [Official validation source](https://github.com/odin-lang/Odin/blob/2c25fb924/core/time/datetime/validation.odin#L7-L105)

4. **[high] ISO/RFC parsing is not a drop-in TOML parser.** `iso8601_to_components(string) -> (datetime.DateTime, utc_offset:int, is_leap:bool, consumed:int)`, `iso8601_to_time_and_offset(...)`, and `iso8601_to_time_utc(...)` exist. The ISO parser accepts `T`, `t`, or space, reads at most nine fractional digits, returns offsets in minutes, and uses `consumed` rather than an error. It does not validate offset hour/minute bounds and may succeed without a zone in some length cases. A 19-byte local date-time without a fraction fails its initial minimum-length check. The RFC3339 parser only reads exactly two fractional digits in this version. Neither supplies local-date-only or local-time-only parsing. TOML therefore needs its own grammar and full-consumption/range checks. Local evidence: `/Users/nathan/Developer/Odin/core/time/iso8601.odin:19-176`; `/Users/nathan/Developer/Odin/core/time/rfc3339.odin:20-196`. [ISO API](https://pkg.odin-lang.org/core/time/#iso8601_to_components) [Official ISO source](https://github.com/odin-lang/Odin/blob/2c25fb924/core/time/iso8601.odin#L19-L176) [RFC API](https://pkg.odin-lang.org/core/time/#rfc3339_to_components)

5. **[high] Built-in formatting is lossy for TOML and allocator-sensitive.** `time_to_rfc3339 :: proc(time: Time, utc_offset:int=0, include_nanos:=true, allocator:=context.allocator) -> (string, bool)` allocates its result with the supplied allocator and strips trailing fractional zeroes. Its implementation appends the supplied offset but does not shift the displayed wall-clock components by that offset, so a UTC `Time` plus nonzero offset is not sufficient without caller adjustment. Date/HMS buffer formatters do not cover full TOML fractional local values. A TOML formatter should write components directly and use stored fraction digit count/lexeme. The caller that owns the allocator owns and must eventually `delete` the allocated RFC3339 string. Local evidence: `/Users/nathan/Developer/Odin/core/time/rfc3339.odin:198-292`; `/Users/nathan/Developer/Odin/core/time/time.odin:550-817`. [Formatting API](https://pkg.odin-lang.org/core/time/#time_to_rfc3339) [Official source](https://github.com/odin-lang/Odin/blob/2c25fb924/core/time/rfc3339.odin#L198-L292)

6. **[medium] Nanoseconds are the maximum built-in component precision.** `datetime.Time.nano:i32`, `time.Duration :: distinct i64`, and `time.Time` all use nanoseconds. The ISO parser silently stops accumulating after nine fractional digits; a strict caller observing `consumed` can reject the remainder, but cannot preserve it through these types. Design implication: `{nanosecond:u32, fraction_digits:u8}` preserves spelling precision only through nine digits; arbitrary extra digits require a decimal digit slice/original source lexeme owned by the TOML document. [Time API](https://pkg.odin-lang.org/core/time/#Duration) [Official source](https://github.com/odin-lang/Odin/blob/2c25fb924/core/time/iso8601.odin#L115-L129)

7. **[medium] Reflection exposes complete field/type metadata.** `reflect.type_kind(typeid) -> Type_Kind`, `underlying_type_kind(typeid)`, `backing_type_kind(typeid)`, `size_of_typeid(typeid)`, `align_of_typeid(typeid)`, and built-ins `typeid_of`, `type_info_of` are available. `Type_Kind` distinguishes named, integer, string, pointer, array/slice/dynamic array, struct, union, enum, map, procedure, etc.; named values require deliberate unwrapping (`any_base`, `any_core`, or `runtime.Type_Info_Named.base`) so custom distinct types are not accidentally treated as primitives before consulting the registry. Local evidence: `/Users/nathan/Developer/Odin/core/reflect/types.odin:43-158`; `/Users/nathan/Developer/Odin/core/reflect/reflect.odin:160-224`; `/Users/nathan/Developer/Odin/base/runtime/core.odin:71-213`. [Reflect API](https://pkg.odin-lang.org/core/reflect/#type_kind) [Built-ins](https://pkg.odin-lang.org/base/builtin/#type_info_of) [Runtime RTTI](https://pkg.odin-lang.org/base/runtime/#Type_Info)

8. **[high] Reflected field lookup yields writable storage, but no general reflected `set` exists.** `Struct_Field` contains `name`, `type:^Type_Info`, `tag`, byte `offset`, and `is_using`. `struct_field_at(typeid,int)`, `struct_field_by_name(typeid,string)`, `struct_fields_zipped(typeid)`, `struct_field_value(any,Struct_Field) -> any`, and `struct_field_value_by_name(any,string,allow_using=false) -> any` compute an `any` whose data pointer addresses the actual field. Assignment must then use pointer type-switch cases (e.g. `switch &x in dst`) or an exact-id/size copy. Raw copy is valid only for exact identical types and is a shallow copy, so it is unsafe as ownership transfer for strings, slices, dynamic arrays, maps, or pointer-containing structs. `set_union_value(dst:any,value:any)->bool` exists only for unions and is explicitly marked unsafe. Local evidence: `/Users/nathan/Developer/Odin/core/reflect/reflect.odin:475-664,1026-1195`. [Field API](https://pkg.odin-lang.org/core/reflect/#struct_field_value) [Union setter](https://pkg.odin-lang.org/core/reflect/#set_union_value) [Language overview: type switches](https://odin-lang.org/docs/overview/#type-switch-statement)

9. **[medium] Struct tags are directly supported and non-allocating views.** Field syntax produces runtime tag strings; `Struct_Tag :: distinct string`, `struct_field_tags(typeid) -> []Struct_Tag`, `struct_tag_get(tag,key) -> string`, and `struct_tag_lookup(tag,key) -> (string,bool)` support conventional space-separated `key:"value"` pairs, escaped bytes, and distinguish absent from explicitly empty tags through `ok`. Returned names/tags/slices are RTTI-backed views and must not be freed. A TOML decoder can use a key such as `toml:"name,omitempty"`, but sub-option splitting is package policy, not supplied by `reflect`. Local evidence: `/Users/nathan/Developer/Odin/core/reflect/reflect.odin:475-500,599-704`; RTTI tag storage `/Users/nathan/Developer/Odin/base/runtime/core.odin:126-150`. [Tag API](https://pkg.odin-lang.org/core/reflect/#struct_tag_lookup) [Official source](https://github.com/odin-lang/Odin/blob/2c25fb924/core/reflect/reflect.odin#L475-L704)

10. **[high] `reflect.is_nil` must not drive TOML nil/omit logic.** Its signature is `is_nil(any) -> bool`, but implementation returns true when the `any` is nil **or every byte of the represented value is zero**. Consequently it reports `0`, `false`, zero-valued structs, and other non-nil values as “nil.” Language `nil` applies to pointer-like/container/procedure/union/`any`/`typeid` categories, while `string` is empty but not nil. Use `value == nil` for an empty `any`, then type-aware checks for nil-capable kinds (and union variant/tag checks); do not equate zero values with unsupported values. Local evidence: `/Users/nathan/Developer/Odin/core/reflect/reflect.odin:226-245`. [Reflect API](https://pkg.odin-lang.org/core/reflect/#is_nil) [Built-in nil documentation](https://pkg.odin-lang.org/base/builtin/#nil)

11. **[medium] Unsupported-value detection should be an explicit `Type_Kind` policy.** After checking a custom converter by exact `typeid`, unwrap named types only for built-in conversion. Accept supported scalar/container/struct kinds; reject or explicitly handle procedures, raw/multi/SoA pointers, `typeid`, `any`, complex/quaternion, bit fields, matrices, and unions that are not the package's optional-value policy. `reflect.deref(any)` is available for `^T`, but pointer following creates cycle/lifetime/null concerns and should be opt-in. [Type kinds](https://pkg.odin-lang.org/core/reflect/#Type_Kind) [Deref API](https://pkg.odin-lang.org/core/reflect/#deref)

12. **[medium] Exact `typeid` registries are supported and preferable to naming conventions.** `typeid` is a unique runtime identifier and is comparable, so `map[typeid]Custom_Decode_Proc`/`map[typeid]Custom_Encode_Proc` is a viable exact-type registry. Lookup must precede named-type unwrapping. RTTI is required (`ODIN_NO_RTTI` must be false); `runtime.type_table` exists but should not be used as the application registry because it is compiler-populated internal runtime state. Local evidence: `/Users/nathan/Developer/Odin/base/runtime/core.odin:174-213`; `/Users/nathan/Developer/Odin/core/reflect/types.odin:78-158`. [Typeid docs](https://pkg.odin-lang.org/base/builtin/#typeid) [Runtime docs](https://pkg.odin-lang.org/base/runtime/#type_table)

13. **[high] Custom conversion needs an explicit allocator/lifetime contract.** Recommended package-defined signatures (these are design APIs, not existing Odin APIs) are:

   ```odin
   Custom_Decode_Proc :: #type proc(
       source: ^Value,
       destination: any,              // points at caller-owned, correctly typed storage
       allocator: mem.Allocator,
   ) -> Error

   Custom_Encode_Proc :: #type proc(
       source: any,
       allocator: mem.Allocator,
   ) -> (value: Value, err: Error)
   ```

   `mem.Allocator` aliases the runtime allocator. Every escaping string/slice/map/dynamic array created by a callback must use the supplied allocator and becomes owned by the successfully decoded result/document; temporary work must use a non-escaping temporary allocator and be released before return. On error, the callback must release its partial allocations and leave `destination` unchanged. The registry map itself remembers its construction allocator and is `delete`d by its registry owner. Do not return an `any` referencing callback-local storage: official docs state an `any` is valid only while its underlying data is valid. Local allocator aliases: `/Users/nathan/Developer/Odin/core/mem/alloc.odin:1-112`; runtime allocator and context: `/Users/nathan/Developer/Odin/base/runtime/core.odin:300-388`. [Allocator guidance/API](https://pkg.odin-lang.org/core/mem/#Allocator) [Any lifetime](https://pkg.odin-lang.org/base/builtin/#any)

## Proposed temporal shapes

```odin
Fraction :: struct {
    nanosecond: u32,       // 0..<1_000_000_000
    digits:      u8,       // 0..9 for normalized storage
    // Optional owned exact_digits/original lexeme when >9-digit round-trip is required.
}

Local_Date :: struct { year: i32, month, day: u8 }
Local_Time :: struct { hour, minute, second: u8, fraction: Fraction }
Local_Date_Time :: struct { date: Local_Date, time: Local_Time }
Offset :: struct { negative: bool, hour, minute: u8 }
Offset_Date_Time :: struct { local: Local_Date_Time, offset: Offset }
```

Using a sign-bearing `Offset` preserves `-00:00`; if package policy rejects/normalizes that spelling, signed total minutes (`i16`) is enough. These types keep the four TOML variants statically distinct, avoid `time.Time`'s range limit, and make formatting independent of timezone databases.

## Sources

- Kept: [`core:time` live package](https://pkg.odin-lang.org/core/time/) — signatures and generated version for public time APIs.
- Kept: [`core:reflect` live package](https://pkg.odin-lang.org/core/reflect/) — reflection, tags, nil helper, and field access APIs.
- Kept: [`base:builtin`](https://pkg.odin-lang.org/base/builtin/) — `any`, `nil`, `typeid`, and RTTI built-ins.
- Kept: [`base:runtime`](https://pkg.odin-lang.org/base/runtime/) — exact RTTI and allocator layouts.
- Kept: [`core:mem`](https://pkg.odin-lang.org/core/mem/) — allocator ownership and resize/lifetime rules.
- Kept: installed local Odin sources under `/Users/nathan/Developer/Odin` — exact version-specific implementation and constraints, linked above to the official repository commit.
- Dropped: third-party tutorials and package comparisons — redundant and not authoritative.
- Dropped: current GitHub issue discussions — useful corroboration for timezone concerns but unnecessary where implementation directly establishes behavior.

## Gaps and residual risks

- The live URL `https://pkg.odin-lang.org/core/time/datetime/` returned 404 even though installed `core:time` imports `core:time/datetime`; therefore component-package claims rely on installed source plus official repository source rather than a live generated subpackage page.
- No command-execution tool was available, so `odin version` and a compile probe could not be run in this research session. The version/commit identity is the task-provided `dev-2026-07:2c25fb924`, and live docs independently identify the `dev-2026-07` family.
- TOML policy still must decide whether formatting is semantic/canonical or byte-round-trip exact. More than nine fractional digits and source separator/case cannot be recovered from Odin datetime values alone.
- Cleanup of arbitrary user-defined destination values cannot be synthesized safely from RTTI. The custom callback contract must own rollback on failure, or the package must add a paired destroy callback.

## Review findings

- **blocker:** `/Users/nathan/Developer/Odin/core/time/datetime/constants.odin:47-108` — no built-in fixed-offset civil type; TOML offset date-time requires TOML-specific state.
- **high:** `/Users/nathan/Developer/Odin/core/time/datetime/validation.odin:72-88` — accepts `nano == 1e9`; enforce a stricter TOML bound.
- **high:** `/Users/nathan/Developer/Odin/core/time/iso8601.odin:107-176` and `rfc3339.odin:111-196` — parsers are not strict/full TOML temporal parsers and lose/limit fractional precision.
- **high:** `/Users/nathan/Developer/Odin/core/reflect/reflect.odin:226-245` — `reflect.is_nil` is zero-byte detection, not semantic nil detection.
- **high:** `/Users/nathan/Developer/Odin/core/reflect/reflect.odin:475-664` — field storage is exposed, but generic assignment/ownership remains package responsibility.

```acceptance-report
{
  "criteriaSatisfied": [
    {
      "id": "criterion-1",
      "status": "satisfied",
      "evidence": "Decision-ready findings include severity, exact local Odin file/line evidence, official URLs, review findings, and residual risks."
    }
  ],
  "changedFiles": [
    ".pi-subagents/artifacts/outputs/7f1ac1c7-460f-4868-946d-126b5276b428/.scratch/toml-package-design/research/odin-temporal-reflection.md"
  ],
  "testsAddedOrUpdated": [],
  "commandsRun": [
    {
      "command": "odin version / compile probe",
      "result": "not-run",
      "summary": "No command-execution tool was available; version was supplied by the task and checked against live docs generation metadata."
    }
  ],
  "validationOutput": [
    "Read installed core/time, core/time/datetime, core/reflect, base/runtime, base/builtin, and core/mem sources.",
    "Cross-checked public APIs against live official Odin package and language documentation."
  ],
  "residualRisks": [
    "No local compile probe was possible in this tool environment.",
    "Lossless handling beyond nanoseconds requires a product decision to retain exact fractional digits or the original lexeme.",
    "Live generated documentation for core:time/datetime returned 404; exact component evidence is from installed and official repository sources."
  ],
  "noStagedFiles": true,
  "diffSummary": "Added only the requested research artifact; no source or tracker files were modified.",
  "reviewFindings": [
    "blocker: core/time/datetime/constants.odin:47-108 - Odin has no built-in fixed-offset civil type for TOML offset date-time.",
    "high: core/time/datetime/validation.odin:72-88 - nano == 1e9 is accepted and needs TOML-side rejection.",
    "high: core/reflect/reflect.odin:226-245 - reflect.is_nil conflates all-zero values with nil.",
    "high: core/reflect/reflect.odin:475-664 - reflection exposes field addresses but has no ownership-safe generic assignment API."
  ],
  "manualNotes": "The artifact is research-only and follows the no-source-edit instruction."
}
```

# Research: installed Odin encoding precedent for a standalone TOML package

## Summary

At the requested Odin source revision (`2c25fb92420bfa31da62e2194b0cc2cb8bd54cf8`), the strongest precedent is JSON's layered API: parse to an owned generic tree, reflection-based marshal/unmarshal, and allocation-free `io.Writer` entry points, with explicit allocator parameters and a recursive destroy procedure. INI contributes a lightweight borrowed iterator and small writer helpers, but its permissive parsing, weak error surface, nondeterministic map writer, and allocator mismatches should not be copied.

**Decision:** TOML should offer (1) borrowed token/iterator or document parsing where useful, (2) owned `Value` parsing plus `destroy_value`, (3) typed `marshal`/`unmarshal`, (4) `marshal_to_writer` as the primitive with builder/allocated-return wrappers, (5) `toml` reflection tags, and (6) precise error unions. It should improve on the installed packages with transactional cleanup, explicit ownership documentation, deterministic output, per-call custom codecs, and focused tests for every allocation/error path.

## Findings

1. **Public API shape to mirror: layered parse, typed conversion, and writer-first output.** JSON exposes `Value` as a scalar/array/object union and groups byte/string overloads under `parse` and `make_parser`; it separately exposes `marshal`, `marshal_to_builder`, `marshal_to_writer`, `unmarshal`, `unmarshal_string`, `unmarshal_any`, `unparse`, and writer/builder variants. See local `core/encoding/json/types.odin:47-63`, `parser.odin:17-49`, `marshal.odin:136-165`, `unmarshal.odin:108-150`, and `unparse.odin:11-36` ([exact-revision source](https://github.com/odin-lang/Odin/blob/2c25fb92420bfa31da62e2194b0cc2cb8bd54cf8/core/encoding/json/types.odin#L47-L63); [live JSON API](https://pkg.odin-lang.org/core/encoding/json/)). INI adds an effective borrowed API: `iterator_from_string` and `iterate` return slices into the input while tracking the current section (`ini.odin:28-76`), plus `load_map_from_string`, path loading, and writer helpers (`ini.odin:80-173`, `ini_os.odin:8-20`) ([exact source](https://github.com/odin-lang/Odin/blob/2c25fb92420bfa31da62e2194b0cc2cb8bd54cf8/core/encoding/ini/ini.odin#L28-L76); [live INI page](https://pkg.odin-lang.org/core/encoding/ini/)). **TOML decision:** expose a small intentional surface—`parse[_string]`, `destroy_value`, `clone_value`, `marshal`, `marshal_to_writer`, `unmarshal[_string]`, and optionally a clearly borrowed iterator/tokenizer. Mark implementation helpers `@(private)`: Odin declarations are public by default ([official package/export semantics](https://odin-lang.org/docs/overview/#exported-names)), whereas the installed JSON package unintentionally publishes many parser and formatting internals.

2. **Use reflection and conventional `toml` tags, but specify their behavior more completely than JSON.** JSON reflection walks RTTI for primitives, arrays, slices, dynamic arrays, maps, structs, unions, enums, and bit sets (`marshal.odin:165-582`). Struct encoding reads `json:"name,omitempty"`, treats `json:"-"` as ignored, supports `jsoncomment`, and flattens `using _: T` (`marshal.odin:450-534`); decoding gives an explicit tag match precedence over an untagged field name and recursively searches anonymous `using _` children (`unmarshal.odin:524-620`). Odin's official convention is a package-named key with comma-separated options, e.g. `json:"username,omitempty"` ([official struct-field tags](https://odin-lang.org/docs/overview/#struct-field-tags)); `reflect.struct_tag_get` is the matching live API ([official reflect package](https://pkg.odin-lang.org/core/reflect/#struct_tag_get)). **TOML decision:** use `toml:"name,omitempty"` and `toml:"-"`; define exact collision, embedded-field, case, unknown-field, duplicate-key, and empty-value rules. Do not inherit JSON's incomplete `omitempty`: its helper only recognizes selected reference/container nil-or-empty states, not numeric zero or `false` (`marshal.odin:444-480`). Do not expose internal writer indentation/state as user options as JSON does (`Marshal_Options` includes internal fields at `marshal.odin:24-58`).

3. **Errors should remain values, with format/data/I/O/allocation distinctions.** JSON parse uses an enum including syntax/token errors plus `.Invalid_Allocator` and `.Out_Of_Memory` (`types.odin:65-88`). Marshal uses `Marshal_Error :: union #shared_nil {Marshal_Data_Error, io.Error}` (`marshal.odin:14-22`); unmarshal uses a richer union of syntax `Error`, data errors, and `Unsupported_Type_Error{id, token}` (`unmarshal.odin:11-27`); unparse combines `io.Error` and allocator error (`unparse.odin:7-10`). INI, by contrast, returns only `runtime.Allocator_Error` from `load_map_from_string`, `(allocator error, ok)` from path loading, and drops save/write errors in `save_map_to_string` (`ini.odin:80-121`, `ini_os.odin:8-20`). Odin's `#shared_nil` error-union behavior is documented officially ([official union tags](https://odin-lang.org/docs/overview/#union-tags)), and writer calls return `io.Error` ([official `core:io`](https://pkg.odin-lang.org/core/io/)). **TOML decision:** define diagnostic syntax errors carrying byte offset/line/column and kind; typed-decode errors carrying destination `typeid` and source position/path; and output errors as a shared-nil union of data and `io.Error`. Propagate allocation failures rather than assert. Apply `@(require_results)` to fallible public entry points, consistent with JSON and the official attribute semantics ([official `@(require_results)`](https://odin-lang.org/docs/overview/#require_results)).

4. **Custom codecs are precedent, but JSON's process-global registry should be avoided.** JSON defines `User_Marshaler :: proc(io.Writer, any, ^Marshal_Options) -> Marshal_Error` and `User_Unmarshaler :: proc(^Parser, any) -> Unmarshal_Error`; lookup occurs before normal RTTI handling (`marshal.odin:60-68,158-174`; `unmarshal.odin:29-36,360-374`). Registration requires a caller-owned `^map[typeid]proc`, one-shot global `set_user_*`, then `register_user_*`; errors report unset or duplicate registry (`marshal.odin:105-134`; `unmarshal.odin:38-107`). Custom unmarshalers also disable the normal up-front validation pass globally if any registry entry exists (`unmarshal.odin:108-137`). **TOML decision:** retain writer-based and parser-based callback signatures, but put codec maps in per-call `Marshal_Options`/`Unmarshal_Options` (or an explicit `Codec_Set`) so ownership, concurrency, tests, and composition are local. Never make the mere presence of one codec disable validation for unrelated types; custom callbacks should consume a well-defined value/token and return normal diagnostics.

5. **Allocator flow and ownership must be explicit and end-to-end.** JSON parser stores its allocator, parse switches `context.allocator` to the explicit argument, objects/arrays carry it, and all parsed strings/keys are cloned with it (`parser.odin:7-14,23-49,135-225`). `destroy_value(value, allocator := context.allocator)` recursively frees object keys, child values, arrays, and strings; `clone_value` deep-clones under the supplied allocator (`types.odin:91-130`). `marshal` and `unparse` allocate a builder using the caller allocator and transfer its backing buffer to the returned `[]byte`/`string`; failure destroys the builder (`marshal.odin:136-156`; `unparse.odin:11-27`). Unmarshal allocates destination strings, slices, dynamic arrays, and map content with the supplied allocator (`unmarshal.odin:108-137,650-852`). Official semantics confirm that `context.allocator` propagates through Odin calls, maps/dynamic arrays remember allocators, manual memory management is required, and strings/slices require correct deletion ([official allocators](https://odin-lang.org/docs/overview/#allocators); [official making/deleting arrays](https://odin-lang.org/docs/overview/#making-and-deleting-slices-and-dynamic-arrays); [official `core:mem`](https://pkg.odin-lang.org/core/mem/)). **TOML decision:** every allocating API takes `allocator := context.allocator`; returned values are caller-owned; document the exact destructor and allocator; retain caller location for allocations; ensure every failure path rolls back partial values. Consider an owning `Document{root, allocator}` so destruction cannot accidentally use a different current allocator.

6. **INI provides useful lightweight ownership precedent, but its destructor has a mismatch.** `Iterator` borrows `_src`; returned section/key/value strings alias the input and need no destruction while the source remains alive (`ini.odin:22-76`). `load_map_from_string` clones sections, keys, and values under the passed allocator and `delete_map` recursively frees them (`ini.odin:78-135`). However, `delete_map` explicitly uses `m.allocator` for keys/values but calls `delete(section)` without that allocator (`ini.odin:123-134`), making destruction depend on the current context for section strings. `load_map_from_path` correctly frees file bytes and destroys a partial map on failure (`ini_os.odin:8-20`). **TOML decision:** distinguish borrowed and owning APIs in names/docs and never mix allocators in destruction; store the allocator in an owning document or require it explicitly at destroy time.

7. **Writer APIs should be the implementation primitive and must preserve errors/counts.** JSON's allocated-return marshal wraps a builder, which wraps `marshal_to_writer`; recursive serialization writes directly to `io.Writer` and propagates `io.Error` with `or_return` (`marshal.odin:136-165,175-582`). INI's `write_section`, `write_pair`, and `write_map` return `(n, io.Error)` and accumulate byte counts (`ini.odin:136-184`). This agrees with official `io.Writer`/`io.write_*` error contracts ([official `core:io`](https://pkg.odin-lang.org/core/io/)). **TOML decision:** implement `marshal_to_writer(w, value, ^Options) -> Marshal_Error` first; add builder and allocated-string wrappers; provide `(n, err)` only where partial byte counts matter. Do not copy `save_map_to_string`, which ignores `write_map`'s error (`ini.odin:117-121`). Deterministic table/key ordering should be explicit and tested; INI map iteration is unordered.

8. **Installed tests establish cleanup and OOM expectations, but coverage is too thin to copy.** JSON tests call `destroy_value` after parse, `delete` marshal output, recursively clean unmarshal-owned strings/slices, and use tiny virtual arenas to assert stable `.Out_Of_Memory` propagation (`tests/core/encoding/json/test_core_json.odin:8-128,131-146,361-409`). They cover UTF-8/surrogates, ignored tags, integer-key maps, empty structs, and enumerated arrays (`test_core_json.odin:390-532`) ([exact test source](https://github.com/odin-lang/Odin/blob/2c25fb92420bfa31da62e2194b0cc2cb8bd54cf8/tests/core/encoding/json/test_core_json.odin#L390-L532)). INI tests cover basic map parse, save, and iteration with explicit cleanup (`tests/core/encoding/ini/test_core_ini.odin:8-119`) ([exact test source](https://github.com/odin-lang/Odin/blob/2c25fb92420bfa31da62e2194b0cc2cb8bd54cf8/tests/core/encoding/ini/test_core_ini.odin#L8-L119)). Official Odin tests run `@(test)` procedures and track leaks/bad frees by default ([official testing guide](https://odin-lang.org/docs/testing/#the-memory-tracker)). **TOML decision:** add parse/marshal/unmarshal round trips, exact writer failures, tags/options/custom codecs, unknown and duplicate fields, all scalar/time forms, malformed input with exact positions, deterministic output, alternate allocator success, OOM at many allocation points, partial-result cleanup, and leak-free destruction. Keep each case atomic enough for parallel test execution.

9. **Quirks to deliberately avoid.** Evidence-backed hazards at this revision are:
   - JSON defaults to JSON5 rather than strict JSON (`types.odin:42`); TOML should have one specification and no surprising permissive default.
   - `is_valid` explicitly does not detect duplicate object keys (`validator.odin:5-7`) and validation/parser entry points do not obviously require EOF after one root value (`validator.odin:8-24`, `parser.odin:40-61`). TOML must reject duplicates required by TOML and reject trailing non-comment content.
   - Parser construction discards the first `advance_token` error and many subsequent advances are unchecked (`parser.odin:23-31,63-94`). Preserve lexical errors with position.
   - Empty JSON object keys are not inserted, despite being legal, and the already-parsed value is not destroyed on that branch (`parser.odin:217-229`). Do not special-case legal empty keys as “no allocation.”
   - Unmarshal writes directly into the destination and allocates new slices/dynamic arrays without first releasing or transactionally replacing existing storage (`unmarshal.odin:779-852`); partial failure can leave caller state partly changed. Decode into temporary owned state, then commit or document destructive replacement precisely.
   - Unknown JSON fields are skipped by swapping in `mem.nil_allocator()` (`unmarshal.odin:620-637`), which couples skipping to parser allocation behavior. Provide a true syntactic skip routine.
   - Duplicate-field tracking is allocated/reset inside the per-key loop and uses field offsets as a bitmap index (`unmarshal.odin:539-613`), making `.Multiple_Use_Field` unreliable. Track by stable field index for the entire object.
   - Global custom-codec maps are one-shot, mutable, caller-owned globals (`marshal.odin:105-134`; `unmarshal.odin:38-107`): unsuitable for parallel tests and libraries.
   - INI silently accepts malformed sections without `]`, ignores non-assignment lines, only recognizes full-line comments, and uses heuristic quote/equal handling (`ini.odin:38-72`). TOML must be grammar-driven and diagnostic.
   - INI output order follows maps; root-section omission depends on root being the first map iteration, so an empty root encountered later can emit `[]` (`ini.odin:166-184`). Never make correctness depend on map iteration order.
   - INI's `key_lower_case` lowercases the raw `key` rather than the already-unquoted `new_key` (`ini.odin:103-108`). Apply transforms to canonical parsed values only.

## Decision-ready TOML API recommendation

```odin
Value :: union {String, Integer, Float, Boolean, Offset_Date_Time, Local_Date_Time, Local_Date, Local_Time, Array, Table}

Parse_Error :: struct {kind: Parse_Error_Kind, pos: Pos}
Decode_Error :: union #shared_nil {Parse_Error, Decode_Data_Error, Unsupported_Type_Error, runtime.Allocator_Error}
Marshal_Error :: union #shared_nil {Marshal_Data_Error, io.Error, runtime.Allocator_Error}

parse        :: proc{parse_bytes, parse_string}
destroy_value :: proc(value: Value, allocator: mem.Allocator)
clone_value   :: proc(value: Value, allocator := context.allocator) -> (Value, runtime.Allocator_Error)

unmarshal        :: proc(data: []byte, ptr: ^$T, opt: Unmarshal_Options = {}, allocator := context.allocator) -> Decode_Error
unmarshal_string :: proc(data: string, ptr: ^$T, opt: Unmarshal_Options = {}, allocator := context.allocator) -> Decode_Error
marshal           :: proc(v: any, opt: Marshal_Options = {}, allocator := context.allocator) -> ([]byte, Marshal_Error)
marshal_to_writer :: proc(w: io.Writer, v: any, opt: ^Marshal_Options) -> Marshal_Error
```

Options should contain only caller-controlled policy. Codec maps should be passed in options or an explicit codec set; mutable indentation/parser state belongs in private encoder/decoder structs. If `destroy_value` keeps a default allocator for familiarity, documentation and examples must always pass the same allocator used by parse; an owning `Document` that stores its allocator is safer.

## Sources

- **Kept:** Installed Odin JSON sources at commit `2c25fb9` ([GitHub tree](https://github.com/odin-lang/Odin/tree/2c25fb92420bfa31da62e2194b0cc2cb8bd54cf8/core/encoding/json)) — primary evidence for API, RTTI/tags, allocators, ownership, codecs, writer paths, and quirks.
- **Kept:** Installed Odin INI sources at commit `2c25fb9` ([GitHub tree](https://github.com/odin-lang/Odin/tree/2c25fb92420bfa31da62e2194b0cc2cb8bd54cf8/core/encoding/ini)) — primary evidence for borrowed iteration, maps, path loading, destruction, and writer helpers.
- **Kept:** Installed JSON and INI tests ([JSON](https://github.com/odin-lang/Odin/blob/2c25fb92420bfa31da62e2194b0cc2cb8bd54cf8/tests/core/encoding/json/test_core_json.odin), [INI](https://github.com/odin-lang/Odin/blob/2c25fb92420bfa31da62e2194b0cc2cb8bd54cf8/tests/core/encoding/ini/test_core_ini.odin)) — executable precedent for cleanup, OOM, tags, round trips, and iterator/map behavior.
- **Kept:** [Official live JSON package](https://pkg.odin-lang.org/core/encoding/json/), [INI package](https://pkg.odin-lang.org/core/encoding/ini/), [reflect](https://pkg.odin-lang.org/core/reflect/), [io](https://pkg.odin-lang.org/core/io/), [language overview](https://odin-lang.org/docs/overview/), and [testing guide](https://odin-lang.org/docs/testing/) — version-sensitive public API and language/memory semantics.
- **Dropped:** Search-result commentary, issues, and pull requests — useful for discovery but unnecessary where exact installed source/tests provide stronger evidence.

## Gaps

- No command-execution tool was available in this research runtime, so `odin version`, `git rev-parse`, `git status`, and `odin test` could not be run. The requested revision was corroborated by reading the installed paths and the same files through commit-pinned GitHub URLs, but repository/working-tree state was not independently queried.
- The live package pages are generated from a newer live compiler snapshot and the INI page omits many undocumented declarations. Exact installed source at the requested revision therefore controls API-shape conclusions; live docs are used for current allocator, tag, visibility, writer, and testing semantics.

```acceptance-report
{
  "criteriaSatisfied": [
    {
      "id": "criterion-1",
      "status": "satisfied",
      "evidence": "Only the required research artifact was written; installed source, tests, and tracker files were not edited."
    },
    {
      "id": "criterion-2",
      "status": "satisfied",
      "evidence": "The brief cites exact local file/line ranges, commit-pinned upstream files, official live Odin URLs, tests, allocator lifetimes, and residual validation gaps."
    }
  ],
  "changedFiles": [
    ".pi-subagents/artifacts/outputs/7f1ac1c7-460f-4868-946d-126b5276b428/.scratch/toml-package-design/research/odin-encoding-precedent.md"
  ],
  "testsAddedOrUpdated": [],
  "commandsRun": [
    {
      "command": "read installed core/encoding/json, core/encoding/ini, and matching tests",
      "result": "passed",
      "summary": "Inspected all eight JSON source files, both INI source files, and both matching test files."
    },
    {
      "command": "fetch official live Odin package/language/testing documentation and commit-pinned GitHub files",
      "result": "passed",
      "summary": "Cross-checked package APIs and version-sensitive allocator, tags, visibility, writer, and test semantics."
    },
    {
      "command": "odin version && git rev-parse HEAD && odin test ... && git status",
      "result": "not-run",
      "summary": "No command-execution tool was available in this research runtime."
    }
  ],
  "validationOutput": [
    "Artifact written to the authoritative output path.",
    "Installed and commit-pinned source content matched for the files inspected.",
    "No source or tracker files were edited."
  ],
  "residualRisks": [
    "Compiler version, repository HEAD, test execution, and staging state could not be independently queried without a command runner.",
    "Live package documentation is newer than the pinned installed source; pinned source is treated as authoritative for precedent."
  ],
  "noStagedFiles": true,
  "diffSummary": "Added one decision-ready research brief; no implementation or test sources changed.",
  "reviewFindings": [
    "no blockers in the research artifact",
    "review gate remains required by the parent reviewer"
  ],
  "manualNotes": "noStagedFiles is based on making no staging calls and editing only the configured artifact; git status was unavailable."
}
```

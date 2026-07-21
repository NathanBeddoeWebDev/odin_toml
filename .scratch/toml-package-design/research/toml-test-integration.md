# Research: Official `toml-test` integration for an Odin TOML 1.1 package

## Summary

Use the upstream `toml-lang/toml-test` **v2.2.0** runner and corpus, pinned to immutable commit **`ce08da1ddb075d1c7596d663c7fcba9a2ae02c5c`**, and explicitly run `-toml=1.1.0`; never infer the suite from every file under `tests/`. Build two test-only Odin executables implementing the runner's one-process-per-case stdin/stdout protocol, and make zero decoder-valid, decoder-invalid, or encoder failures—and zero undocumented skips—the CI gate.

The official suite establishes language-level semantic conformance, not the package's allocator/ownership behavior, diagnostics, deterministic encoding policy, precision beyond milliseconds, resource limits, malformed encoder-adapter inputs, or broad round-trip/property behavior. Those remain local test obligations.

## Findings

1. **Repository identity and pin.** The project moved from `BurntSushi/toml-test` to `toml-lang/toml-test`; GitHub redirects the old location, but new integration should use the canonical owner. The current documented release is v2.2.0, whose lightweight tag resolves to commit `ce08da1ddb075d1c7596d663c7fcba9a2ae02c5c`. Upstream explicitly recommends a binary or tagged release in CI so test changes do not break consumers. Pin both the human-readable tag and full SHA in project metadata, and have an update PR change them together. [README at pinned commit](https://github.com/toml-lang/toml-test/blob/ce08da1ddb075d1c7596d663c7fcba9a2ae02c5c/README.md) [immutable tag target evidence](https://github.com/toml-lang/toml-test/commit/ce08da1ddb075d1c7596d663c7fcba9a2ae02c5c)

2. **Version selection is a manifest/filter, not a directory copy.** The corpus supports 1.0.0 and 1.1.0, and some syntax changes category between versions (the README uses inline-table trailing commas as its example). `NewRunner` normalizes `1.1` and `latest` to `1.1.0`; however, the library's `DefaultVersion` at the pinned commit is still `1.0.0`, so an integration relying on defaults can silently test the wrong language. The runner computes the applicable set using generated version exclusions; for a native runner/copy, the authoritative alternative is `tests/files-toml-1.1.0`, or `toml-test copy -toml=1.1`. [runner version/filter source](https://github.com/toml-lang/toml-test/blob/ce08da1ddb075d1c7596d663c7fcba9a2ae02c5c/runner.go) [1.1 file manifest](https://github.com/toml-lang/toml-test/blob/ce08da1ddb075d1c7596d663c7fcba9a2ae02c5c/tests/files-toml-1.1.0) [README warning](https://github.com/toml-lang/toml-test/blob/ce08da1ddb075d1c7596d663c7fcba9a2ae02c5c/README.md#usage-without-toml-test-binary)

3. **Corpus formats.** Decoder-valid cases are paired `tests/valid/<name>.toml` and `.json`; decoder-invalid cases are standalone `tests/invalid/<name>.toml` and only assert rejection. Internally the runner mirrors valid files into a virtual `encoder/` tree: encoder input is the valid case's tagged `.json`, and expected output semantics come from its paired `.toml`. The 1.1 manifest lists only physical invalid TOML files and valid TOML/JSON pairs; encoder cases are synthesized rather than separately stored. [README formats](https://github.com/toml-lang/toml-test/blob/ce08da1ddb075d1c7596d663c7fcba9a2ae02c5c/README.md#adding-tests) [runner mirroring and I/O source](https://github.com/toml-lang/toml-test/blob/ce08da1ddb075d1c7596d663c7fcba9a2ae02c5c/runner.go)

4. **Tagged JSON representation.** Tables are JSON objects, arrays are JSON arrays, and every scalar is exactly `{"type":"…","value":"…"}`, with `value` always a JSON string. Allowed tags are `string`, `integer`, `float`, `bool`, `datetime` (offset), `datetime-local`, `date-local`, and `time-local`; empty tables/arrays are `{}`/`[]`, and JSON numbers, booleans, and null are never used. Integer values are semantic decimal strings, not source lexemes (e.g. `0xDEADBEEF` expects `"3735928559"`). Offset datetime uses RFC 3339; local forms use the corresponding RFC 3339 shape without offset. [encoding specification](https://github.com/toml-lang/toml-test/blob/ce08da1ddb075d1c7596d663c7fcba9a2ae02c5c/README.md#json-encoding) [integer canonicalization fixture](https://github.com/toml-lang/toml-test/blob/ce08da1ddb075d1c7596d663c7fcba9a2ae02c5c/tests/valid/integer/literals.json)

5. **Decoder adapter protocol.** For each case the runner starts the command anew, sends the complete TOML document on stdin through EOF, and expects either (a) valid: exit 0, no stderr, and nonempty tagged JSON on stdout; or (b) invalid: **exactly exit 1**. Although the README says “non-zero,” the current executable only converts exit code 1 into an expected parse rejection; exit 2, signals, panic, timeout, or spawn failure fail the suite. `CommandParser` treats any stderr bytes as the error stream, so a successful decoder must keep stderr completely quiet. Each case defaults to a one-second timeout and tests may run concurrently. [actual process and pass/fail source](https://github.com/toml-lang/toml-test/blob/ce08da1ddb075d1c7596d663c7fcba9a2ae02c5c/runner.go) [documented decoder interface](https://github.com/toml-lang/toml-test/blob/ce08da1ddb075d1c7596d663c7fcba9a2ae02c5c/README.md#implementing-a-decoder)

6. **Decoder comparison semantics.** JSON object key order and whitespace do not matter. Array order, table/value distinction, keys, scalar tags, and integer/string values do matter. Floats are parsed as float64 and compared numerically; NaN spelling/sign is normalized. Booleans are compared case-insensitively. Date/time values are parsed and compared semantically, including equivalent offset datetimes. The adapter should nevertheless emit deterministic, canonical JSON for useful failure artifacts. [comparison source](https://github.com/toml-lang/toml-test/blob/ce08da1ddb075d1c7596d663c7fcba9a2ae02c5c/json.go)

7. **Encoder adapter and expectations.** The runner starts the encoder per valid case, sends tagged JSON on stdin, and requires exit 0, silent stderr, and valid TOML on stdout. It parses both the reference TOML and encoder output with its blessed BurntSushi decoder and recursively compares semantic values, so lexical form, table ordering, quoting style, base, and equivalent datetime-offset spelling are not prescribed. Type still matters (integer is not float), array order matters, and all keys/values must survive. [encoder interface](https://github.com/toml-lang/toml-test/blob/ce08da1ddb075d1c7596d663c7fcba9a2ae02c5c/README.md#implementing-an-encoder) [encoder execution](https://github.com/toml-lang/toml-test/blob/ce08da1ddb075d1c7596d663c7fcba9a2ae02c5c/runner.go) [semantic comparison](https://github.com/toml-lang/toml-test/blob/ce08da1ddb075d1c7596d663c7fcba9a2ae02c5c/toml.go)

8. **A source-level mismatch matters for encoder-negative claims.** README prose mentions encoders rejecting invalid representations, but the pinned implementation synthesizes encoder tests only from `valid/`, and `runInvalid` selects the decoder. Therefore v2.2.0's standard CLI run does **not** establish rejection of malformed JSON, unknown/missing tags, non-string tagged values, unrepresentable internal values, cycles, or other encoder API errors. Test those locally rather than claiming official coverage. [test-tree construction and dispatch](https://github.com/toml-lang/toml-test/blob/ce08da1ddb075d1c7596d663c7fcba9a2ae02c5c/runner.go)

9. **Licensing and redistribution.** The runner and corpus are MIT licensed, copyright TOML authors (2018), and redistribution requires retaining the copyright and permission notice in copies or substantial portions. If fixtures or a runner binary are vendored, include the pinned upstream `LICENSE` adjacent to them and record source, tag, SHA, TOML version, and update procedure. If CI downloads/builds the tool without committing it, still record the pin and provenance for reproducibility. [MIT license](https://github.com/toml-lang/toml-test/blob/ce08da1ddb075d1c7596d663c7fcba9a2ae02c5c/LICENSE) [copy command provenance file](https://github.com/toml-lang/toml-test/blob/ce08da1ddb075d1c7596d663c7fcba9a2ae02c5c/cmd/toml-test/copy.go)

## Recommended exact integration contract

### Pin and acquisition

- Canonical upstream: `https://github.com/toml-lang/toml-test`.
- Tool/corpus version: `v2.2.0`.
- Immutable commit: `ce08da1ddb075d1c7596d663c7fcba9a2ae02c5c`.
- TOML suite: literal `1.1.0` (not `latest`, not an omitted flag).
- Prefer a CI-only pinned tool; it is not a runtime dependency of the standalone Odin package. Fetch a release artifact with a repository-recorded SHA-256, or checkout the full commit SHA and build the runner. Do not execute `@latest` or track `main`.
- If an offline/native test corpus is desired, generate it only with `toml-test v2.2.0 copy -toml=1.1.0 <dir>`, retain `.gitattributes`, `version.toml`, and the MIT license, and verify its paths against the pinned 1.1 manifest. Do not copy the entire upstream `tests/` tree.

### Test-only executables

Provide two thin binaries outside the public package API:

- `toml_test_decoder`: read stdin as raw bytes to EOF; invoke the same public TOML 1.1 parse entry point users call; recursively convert the resulting Odin value tree to tagged JSON; on success write only JSON to stdout and exit 0; on parse/UTF-8/limit failure write a diagnostic only to stderr and exit exactly 1.
- `toml_test_encoder`: read tagged JSON to EOF; strictly validate and convert the eight scalar tags plus arrays/tables to the public Odin value model; invoke the same public serializer users call; on success write only TOML to stdout and exit 0; on adapter/input/serialization failure write only stderr and exit exactly 1.
- Neither adapter may log progress. Both must be reentrant across independently launched concurrent processes, release all temporary allocations on exit, preserve array order and exact key strings, distinguish all four temporal kinds, serialize integers to decimal tagged strings in the decoder, and handle float `inf`/`nan` spellings accepted by the comparator.

### Required CI invocation and gate

After compiling the adapters to paths without whitespace, run the equivalent of:

```sh
toml-test test \
  -toml=1.1.0 \
  -decoder=./build/toml_test_decoder \
  -encoder=./build/toml_test_encoder \
  -timeout=5s \
  -parallel=4 \
  -color=never \
  -json
```

The modest explicit parallelism and timeout make CI behavior stable while remaining stricter than an unbounded harness. The gate is: runner exit 0; `failed_valid == 0`, `failed_invalid == 0`, `failed_encoder == 0`; `skipped == 0`. Any skip requires a reviewed, named exception with rationale and removal condition; use `-skip-must-err` when maintaining temporary upstream-test skips so a fixed test cannot remain hidden. Preserve the JSON report as a CI artifact. Run ordinary Odin unit tests separately; passing the adapters alone must not substitute for public-API tests.

### Local tests still required

1. Public API shape and Odin-specific behavior: allocator selection, ownership/lifetime, cleanup on every failure path, nil/empty distinctions, error/result contracts, and thread safety.
2. Diagnostics: stable error categories, byte/line/column spans, useful messages, and rejection without partial output. Official invalid cases generally assert only exit 1.
3. Encoder-negative cases omitted by the runner: malformed tagged values (for the adapter) and unsupported/cyclic/over-depth public values, if representable by the API.
4. Deterministic encoding policy: key/table ordering, quoting/escaping choices, newline policy, canonical integer/float/datetime spelling, and byte-for-byte golden output. Official encoder checks semantic equivalence only.
5. Precision policy beyond milliseconds and required truncation rather than rounding; timezone-offset retention policy where the public model promises it. Upstream explicitly tests only milliseconds.
6. Resource limits and adversarial behavior: deep dotted keys/tables, huge arrays/strings/documents, timeout/OOM resistance, integer overflow boundaries, and configured nesting limit. Upstream recommends a nesting limit but does not test it.
7. Round-trip/property/fuzz tests over the full public value domain and parser byte input, including malformed UTF-8, CR/LF variants, EOF boundaries, embedded NUL/control bytes, and serializer→parser semantic identity.
8. Features outside semantic TOML conformance, if offered: comment/trivia preservation, source-order preservation, streaming/incremental parsing, file APIs, and platform-specific I/O behavior.
9. Packaging matrix: supported Odin versions, OS/architectures, debug/release modes, and tests proving the published package has no Go or `toml-test` runtime dependency.

## Sources

- Kept: [Pinned README](https://github.com/toml-lang/toml-test/blob/ce08da1ddb075d1c7596d663c7fcba9a2ae02c5c/README.md) — primary protocol, tagged JSON, version-copy warning, and explicit coverage limits.
- Kept: [Pinned runner.go](https://github.com/toml-lang/toml-test/blob/ce08da1ddb075d1c7596d663c7fcba9a2ae02c5c/runner.go) — authoritative process behavior, exact exit handling, version filtering, test synthesis, timeout, and comparison dispatch.
- Kept: [Pinned json.go](https://github.com/toml-lang/toml-test/blob/ce08da1ddb075d1c7596d663c7fcba9a2ae02c5c/json.go) — decoder comparison semantics.
- Kept: [Pinned toml.go](https://github.com/toml-lang/toml-test/blob/ce08da1ddb075d1c7596d663c7fcba9a2ae02c5c/toml.go) — encoder semantic comparison.
- Kept: [Pinned TOML 1.1 manifest](https://github.com/toml-lang/toml-test/blob/ce08da1ddb075d1c7596d663c7fcba9a2ae02c5c/tests/files-toml-1.1.0) — authoritative physical corpus selection for native/offline runners.
- Kept: [Pinned CLI test source](https://github.com/toml-lang/toml-test/blob/ce08da1ddb075d1c7596d663c7fcba9a2ae02c5c/cmd/toml-test/test.go) — v2 CLI flags and JSON result/gating behavior.
- Kept: [Pinned license](https://github.com/toml-lang/toml-test/blob/ce08da1ddb075d1c7596d663c7fcba9a2ae02c5c/LICENSE) — redistribution terms.
- Dropped: repository landing page on `main` — mutable and potentially newer than the selected integration.
- Dropped: old v1.3.0 fixture links and third-party integration articles — stale for the v2.2.0 runner and unnecessary where primary source exists.
- Dropped: historical pull requests/issues — useful context but not authoritative for the current contract.

## Gaps

- No release-asset SHA-256 can be recommended without choosing an OS/architecture artifact. The implementation PR should record the checksum of each exact downloaded v2.2.0 asset, or avoid this gap by building from the full pinned source commit.
- Actual pass/fail counts depend on the eventual Odin implementation and were not run because this task is research-only and no adapters exist yet. Acceptance should review the first stored `-json` report and confirm zero skipped tests.
- Upstream documentation says decoder errors may be any nonzero status, while pinned runner code requires exactly 1. This brief deliberately follows executable behavior; re-check on every pin update.

```acceptance-report
{
  "criteriaSatisfied": [
    {
      "id": "criterion-1",
      "status": "satisfied",
      "evidence": "Completed only the requested research and wrote the decision-ready brief; no source or tracker files were edited."
    },
    {
      "id": "criterion-2",
      "status": "satisfied",
      "evidence": "Findings cite primary upstream files at immutable v2.2.0 commit ce08da1ddb075d1c7596d663c7fcba9a2ae02c5c and provide an exact pin, adapter protocol, CI command/gate, licensing rule, and local coverage obligations."
    }
  ],
  "changedFiles": [
    ".pi-subagents/artifacts/outputs/7f1ac1c7-460f-4868-946d-126b5276b428/.scratch/toml-package-design/research/toml-test-integration.md"
  ],
  "testsAddedOrUpdated": [],
  "commandsRun": [
    {
      "command": "Read issue 04 and inspect pinned upstream README.md, runner.go, json.go, toml.go, cmd sources, TOML 1.1 manifest, fixtures, CHANGELOG, go.mod, and LICENSE",
      "result": "passed",
      "summary": "Primary-source evidence gathered; v2.2.0 tag target independently resolved through GitHub API."
    },
    {
      "command": "Run toml-test against Odin adapters",
      "result": "not-run",
      "summary": "Research-only task; adapters are not implemented yet."
    }
  ],
  "validationOutput": [
    "Confirmed refs/tags/v2.2.0 resolves to commit ce08da1ddb075d1c7596d663c7fcba9a2ae02c5c.",
    "Confirmed pinned runner DefaultVersion is 1.0.0, so the contract explicitly selects TOML 1.1.0.",
    "Confirmed executable behavior requires invalid decoder cases to exit exactly 1 and valid commands to keep stderr empty.",
    "Confirmed encoder cases are synthesized from valid fixtures and compared semantically through the blessed decoder."
  ],
  "residualRisks": [
    "Release binary checksums remain platform-specific and must be recorded when CI acquisition is implemented.",
    "No conformance result exists until the Odin adapters are implemented and the pinned runner is executed.",
    "The upstream README's generic nonzero-error wording conflicts with the pinned runner's exact-exit-1 behavior; executable source governs this recommendation."
  ],
  "noStagedFiles": true,
  "diffSummary": "Added one research artifact only; no package source, tests, or tracker files changed.",
  "reviewFindings": [
    "no blockers in the research brief; implementation remains subject to the required reviewer gate"
  ],
  "manualNotes": "The official standard CLI does not exercise malformed encoder inputs despite README prose that can be read more broadly; retain explicit local encoder-negative tests."
}
```

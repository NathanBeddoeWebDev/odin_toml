# Release evidence bundle

[`manifest.json`](manifest.json) is the tracked release contract. It binds the compiler, official TOML corpus, float oracle, conformance reports, generated-test seed and fuzz selectors, allocator/writer sweeps, supported native target/mode matrix, sanitizer/race campaigns, and non-gating baselines.

## Tracked review

From a clean checkout with the pinned compiler on `PATH`:

```sh
scripts/prepare_test_dependencies.sh
scripts/check_documentation.sh
scripts/check.sh
```

The first command fetches only the pinned test sources under ignored `build/`. The documentation command compiles and executes every public example in normal and speed modes. The complete check reruns documentation examples together with the full correctness, conformance, property/fuzz replay, allocator/writer, strictness, bad-memory, consumer, and cross-target typecheck suite.

Validate the tracked manifest and baseline schemas separately with:

```sh
scripts/assemble_release_bundle.py check-tracked
```

This verifies pins and reviewed conformance counts, zero conformance skips/failures, the complete benchmark/size category sets, fixture hashes, and the absence of performance threshold fields. Baseline timing and size values are observations and are never compared as release gates.

## Native CI assembly

Native platform and sanitizer reports cannot be truthfully manufactured on one host. The `release-evidence` workflow job waits for every supported native matrix job and the native Linux ThreadSanitizer job, downloads their reports without flattening them, then runs:

```sh
scripts/assemble_release_bundle.py assemble \
  --reports-root <downloaded-artifacts> \
  --output <bundle-directory> \
  --source-revision <git-sha> \
  --run-id <ci-run-id>
```

Assembly fails closed unless it receives, for each of `linux_amd64`, `linux_arm64`, `darwin_amd64`, `darwin_arm64`, and `windows_amd64`:

- a native public-suite report for `minimal` and `speed` with strict and bad-memory modes enabled;
- a native AddressSanitizer/libFuzzer report covering every public fuzz target for at least 300 aggregate seconds;
- zero skips, expected failures, sanitizer findings, race findings, memory reports, and unresolved minimized defects.

It additionally requires genuine native `linux_amd64` ThreadSanitizer evidence for frozen-registry concurrent reads. Report `platform` and `target` must match, so a cross-labeled local report cannot satisfy native evidence.

The uploaded `release-bundle` artifact contains tracked evidence, all eleven CI reports, their preserved correctness/sanitizer logs, and `resolved-manifest.json`. Every report records the source revision and CI run ID, and the assembler rejects evidence from another revision or run before copying it. Report metadata binds each preserved log by byte count and SHA-256; the resolved manifest then records the SHA-256 of every bundle member. Reviewers can inspect the completed acceptance-gate ledger, read the raw logs, verify every zero-tolerance counter, and trace each result to its native job. Missing, altered, inconsistent, stale, short, or nonzero required evidence prevents assembly and release.

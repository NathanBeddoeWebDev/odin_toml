#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

read_lock() {
  local file=$1 key=$2
  awk -F'"' -v key="$key" '$1 == key " = " {print $2}' "$file"
}

lock=tests/corpus/toml-test.lock
source=$(read_lock "$lock" source)
revision=$(read_lock "$lock" revision)
tag=$(read_lock "$lock" tag)
toml_version=$(read_lock "$lock" toml_version)
license=$(read_lock "$lock" license)
expected_odin=$(read_lock toolchain/odin.lock version)

# Keep this literal guard adjacent to the literal runner flag below. The
# official runner defaults to TOML 1.0, so accepting another lock value here
# would silently change the language gate.
test "$toml_version" = "1.1.0"
test -d build/deps/toml-test/.git
test "$(git -C build/deps/toml-test rev-parse HEAD)" = "$revision"
test "$(git -C build/deps/toml-test tag --points-at HEAD)" = "$tag"
test -z "$(git -C build/deps/toml-test status --porcelain)"
cmp tests/corpus/toml-test.LICENSE build/deps/toml-test/LICENSE
test "$(odin version)" = "odin version $expected_odin"

mkdir -p build/reports build/tools
(
  cd build/deps/toml-test
  go build -trimpath -o "$repo_root/build/tools/toml-test" ./cmd/toml-test
)
runner_version=$(build/tools/toml-test version)
[[ "$runner_version" == "toml-test v2.2.0;"* ]]
odin build cmd/toml_test_decoder -file \
  -out:build/tools/toml-test-decoder \
  -vet -vet-style -warnings-as-errors

report=build/reports/toml-test-decoder.json
build/tools/toml-test test \
  -toml=1.1.0 \
  -decoder=./build/tools/toml-test-decoder \
  -timeout=5s \
  -parallel=4 \
  -color=never \
  -json > "$report"

preserved=tests/corpus/toml-test-decoder-report.json
evidence=build/reports/toml-test-decoder-evidence.json
python3 - \
  "$report" "$preserved" "$evidence" \
  "$source" "$revision" "$tag" "$license" "$expected_odin" <<'PY'
import json
import platform
import sys

(
    path,
    preserved_path,
    evidence_path,
    expected_source,
    revision,
    tag,
    expected_license,
    expected_odin,
) = sys.argv[1:]
with open(path, encoding="utf-8") as source:
    report = json.load(source)
with open(preserved_path, encoding="utf-8") as source:
    preserved = json.load(source)

failures = []
expected = {
    "version": "toml-test v2.2.0",
    "toml": "1.1.0",
    "failed_valid": 0,
    "failed_invalid": 0,
    "skipped": 0,
}
for key, value in expected.items():
    if report.get(key) != value:
        failures.append(f"{key}: expected {value!r}, got {report.get(key)!r}")
if report.get("failed_encoder") != 0:
    failures.append(f"unexpected encoder failures: {report.get('failed_encoder')!r}")
if report.get("encoder"):
    failures.append("decoder-only ticket unexpectedly configured an encoder")
flags = report.get("flags", [])
if "-toml=1.1.0" not in flags:
    failures.append("runner report does not contain literal -toml=1.1.0")
if any(flag.startswith("-skip") for flag in flags):
    failures.append("runner report contains a skip flag")
if report.get("tests"):
    failures.append("runner report contains failing test details")
provenance = preserved.get("provenance", {})
if (
    provenance.get("source") != expected_source
    or provenance.get("revision") != revision
    or provenance.get("tag") != tag
    or provenance.get("license") != expected_license
):
    failures.append("preserved report provenance differs from the corpus lock")
if provenance.get("odin") != expected_odin:
    failures.append("preserved report compiler differs from the Odin lock")
if not provenance.get("platform"):
    failures.append("preserved report does not identify its execution platform")
if preserved.get("result") != report:
    failures.append("preserved machine-readable result differs from this complete run")
if preserved.get("command") != report.get("flags"):
    failures.append("preserved command differs from the runner-reported flags")
if failures:
    raise SystemExit("official decoder gate failed:\n- " + "\n- ".join(failures))

machine = platform.machine().lower()
machine = {"x86_64": "amd64", "aarch64": "arm64"}.get(machine, machine)
runtime_platform = f"{platform.system().lower()}_{machine}"
evidence = {
    "schema": 1,
    "provenance": {
        "source": expected_source,
        "tag": tag,
        "revision": revision,
        "license": expected_license,
        "odin": expected_odin,
        "platform": runtime_platform,
    },
    "command": report["flags"],
    "result": report,
}
with open(evidence_path, "w", encoding="utf-8") as destination:
    json.dump(evidence, destination, ensure_ascii=False, indent=2)
    destination.write("\n")

print(
    "official TOML decoder gate passed: "
    f"pin={tag}@{revision} toml={report['toml']} "
    f"valid={report['passed_valid']} invalid={report['passed_invalid']} skips=0 "
    f"platform={runtime_platform}"
)
PY

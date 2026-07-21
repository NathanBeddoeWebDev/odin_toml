#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

expected_version=$(awk -F'"' '/^version = / {print $2}' toolchain/odin.lock)
actual_version=$(odin version)
if [[ "$actual_version" != "odin version $expected_version" ]]; then
  printf 'expected Odin %s, got %s\n' "$expected_version" "$actual_version" >&2
  exit 1
fi

mkdir -p build/reports
{
  printf '%s\n\n' "$actual_version"
  odin report
} > build/reports/compiler.txt

scripts/check_public_api.py

common=(-vet -vet-style -warnings-as-errors)
odin check . -no-entry-point "${common[@]}"
odin check temporal -no-entry-point "${common[@]}"
for target in linux_amd64 linux_arm64 darwin_amd64 darwin_arm64 windows_amd64; do
  odin check . -no-entry-point "-target:$target" "${common[@]}"
done

for mode in minimal speed; do
  odin test tests/support "-o:$mode" "${common[@]}" \
    -define:ODIN_TEST_THREADS=1 \
    -define:ODIN_TEST_RANDOM_SEED=123456789 \
    -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true
  odin test tests/temporal "-o:$mode" "${common[@]}" \
    -define:ODIN_TEST_THREADS=1 \
    -define:ODIN_TEST_RANDOM_SEED=123456789 \
    -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true
  odin test tests/allocator_gate "-o:$mode" "${common[@]}" \
    -define:TOML_ALLOCATOR_GATE_TESTING=true \
    -define:ODIN_TEST_THREADS=1 \
    -define:ODIN_TEST_RANDOM_SEED=123456789 \
    -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true
  odin test tests/codec_registry "-o:$mode" "${common[@]}" \
    -define:ODIN_TEST_THREADS=1 \
    -define:ODIN_TEST_RANDOM_SEED=123456789 \
    -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true
  odin test tests/semantic_lifecycle "-o:$mode" "${common[@]}" \
    -define:ODIN_TEST_THREADS=1 \
    -define:ODIN_TEST_RANDOM_SEED=123456789 \
    -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true
  odin test tests/semantic_mutation "-o:$mode" "${common[@]}" \
    -define:ODIN_TEST_THREADS=1 \
    -define:ODIN_TEST_RANDOM_SEED=123456789 \
    -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true
  odin test tests/scalar_parse "-o:$mode" "${common[@]}" \
    -define:ODIN_TEST_THREADS=1 \
    -define:ODIN_TEST_RANDOM_SEED=123456789 \
    -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true
  odin test tests/container_parse "-o:$mode" "${common[@]}" \
    -define:ODIN_TEST_THREADS=1 \
    -define:ODIN_TEST_RANDOM_SEED=123456789 \
    -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true
  odin test tests/table_parse "-o:$mode" "${common[@]}" \
    -define:ODIN_TEST_THREADS=1 \
    -define:ODIN_TEST_RANDOM_SEED=123456789 \
    -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true
  odin test tests/float_parse "-o:$mode" "${common[@]}" \
    -define:TOML_DECIMAL_GATE_TESTING=true \
    -define:ODIN_TEST_THREADS=1 \
    -define:ODIN_TEST_RANDOM_SEED=123456789 \
    -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true
  odin test tests/float_format "-o:$mode" "${common[@]}" \
    -define:TOML_BINARY64_FORMAT_GATE_TESTING=true \
    -define:TOML_DECIMAL_GATE_TESTING=true \
    -define:ODIN_TEST_THREADS=1 \
    -define:ODIN_TEST_RANDOM_SEED=123456789 \
    -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true
done

scripts/check_float_format_oracle.sh

for zone in UTC Pacific/Kiritimati America/Los_Angeles; do
  TZ="$zone" odin test tests/temporal -o:minimal "${common[@]}" \
    -define:ODIN_TEST_THREADS=1 \
    -define:ODIN_TEST_RANDOM_SEED=123456789 \
    -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true
done

work=$(mktemp -d "${TMPDIR:-/tmp}/odin-toml-check.XXXXXX")
trap 'rm -rf "$work"' EXIT
for mode in minimal speed; do
  odin build tests/consumer_semantic "-o:$mode" "${common[@]}" -out:"$work/semantic-$mode"
  odin build tests/consumer_typed "-o:$mode" "${common[@]}" -out:"$work/typed-$mode"
  odin build examples/semantic_lifecycle "-o:$mode" "${common[@]}" -out:"$work/semantic-lifecycle-$mode"
  "$work/semantic-lifecycle-$mode"
done

scripts/probe_rtti.sh
scripts/probe_no_rtti.sh

printf 'all normal and optimized scaffold checks and feasibility probes passed\n'

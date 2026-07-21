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

for mode in minimal speed; do
  odin test tests/support "-o:$mode" "${common[@]}" \
    -define:ODIN_TEST_THREADS=1 \
    -define:ODIN_TEST_RANDOM_SEED=123456789 \
    -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true
  odin test tests/temporal "-o:$mode" "${common[@]}" \
    -define:ODIN_TEST_THREADS=1 \
    -define:ODIN_TEST_RANDOM_SEED=123456789 \
    -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true
  odin test tests/float_parse "-o:$mode" "${common[@]}" \
    -define:TOML_DECIMAL_GATE_TESTING=true \
    -define:ODIN_TEST_THREADS=1 \
    -define:ODIN_TEST_RANDOM_SEED=123456789 \
    -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true
done

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
done

scripts/probe_rtti.sh
scripts/probe_no_rtti.sh

printf 'all normal and optimized scaffold checks and feasibility probes passed\n'

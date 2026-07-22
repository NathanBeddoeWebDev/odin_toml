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
report=build/reports/rtti-feasibility.txt
: >"$report"
printf '%s\n' "$actual_version" | tee -a "$report"

common=(-collection:external="$repo_root/external" -vet -vet-style -warnings-as-errors)
for mode in minimal speed; do
  odin run tests/rtti_probe "-o:$mode" "${common[@]}"
  printf 'RTTI feasibility probe passed in %s mode\n' "$mode" | tee -a "$report"
done

printf 'supported RTTI mechanisms are green (see %s)\n' "$report"

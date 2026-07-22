#!/usr/bin/env bash
# Compile and execute every public consumer example with the pinned compiler.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

expected_version=$(awk -F'"' '/^version = / {print $2}' toolchain/odin.lock)
actual_version=$(odin version)
if [[ "$actual_version" != "odin version $expected_version" ]]; then
  printf 'expected Odin %s, got %s\n' "$expected_version" "$actual_version" >&2
  exit 1
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/odin-toml-documentation.XXXXXX")
trap 'rm -rf "$work"' EXIT
common=(-vet -vet-style -warnings-as-errors)
examples=(
  semantic_lifecycle
  typed_unmarshal_cleanup
  consumer_contract
)

for mode in minimal speed; do
  for example in "${examples[@]}"; do
    output="$work/$example-$mode"
    odin build "examples/$example" "-o:$mode" "${common[@]}" -out:"$output"
    "$output"
  done
  # Compile the public-API benchmark driver, but never time or compare it here.
  odin build benchmarks "-o:$mode" "${common[@]}" -out:"$work/benchmarks-$mode"
done

printf 'public documentation examples passed in minimal and speed modes\n'

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
report=build/reports/no-rtti.txt

set +e
odin check tests/consumer_semantic \
  -target:freestanding_amd64_sysv \
  -no-rtti \
  -vet -vet-style -warnings-as-errors >"$report" 2>&1
status=$?
set -e

if [[ $status -eq 0 ]]; then
  echo "Reference Odin now accepts the semantic consumer with RTTI disabled; reopen the recorded design review." >&2
  exit 1
fi
if ! grep -q "Use of a type, any, which has been disallowed" "$report" ||
   ! grep -Eq "/(marshal|codecs)\\.odin" "$report"; then
  cat "$report" >&2
  echo "RTTI-disabled failure changed and no longer matches the reviewed typed-declaration boundary." >&2
  exit 1
fi

printf 'reproduced the documented semantic-consumer RTTI blocker (see %s)\n' "$report"

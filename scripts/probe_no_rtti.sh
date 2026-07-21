#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"
mkdir -p build/reports
report=build/reports/no-rtti.txt

set +e
odin check . \
  -no-entry-point \
  -target:freestanding_amd64_sysv \
  -no-rtti \
  -vet -vet-style -warnings-as-errors >"$report" 2>&1
status=$?
set -e

if [[ $status -eq 0 ]]; then
  echo "Reference Odin now accepts the frozen package with RTTI disabled; reopen the recorded design review." >&2
  exit 1
fi
if ! grep -q "Use of a type, any, which has been disallowed" "$report"; then
  cat "$report" >&2
  echo "RTTI-disabled failure changed and no longer matches the reviewed compiler boundary." >&2
  exit 1
fi

printf 'reproduced the documented Reference Odin RTTI-disabled incompatibility (see %s)\n' "$report"

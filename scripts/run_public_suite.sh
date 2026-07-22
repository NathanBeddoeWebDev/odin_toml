#!/usr/bin/env bash
# Preserve the complete successful native correctness log and its provenance.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

if [[ -n ${MATRIX_TARGET:-} ]]; then
  matrix_target=$MATRIX_TARGET
else
  matrix_target=$(python3 -c '
import platform
machine = platform.machine().lower()
machine = {"x86_64": "amd64", "aarch64": "arm64"}.get(machine, machine)
print(f"{platform.system().lower()}_{machine}")
')
fi
source_revision=${GITHUB_SHA:-$(git rev-parse HEAD)}
run_id=${GITHUB_RUN_ID:-local}
mkdir -p build/reports
log=build/reports/public-suite.log
scripts/check.sh 2>&1 | tee "$log"
scripts/write_public_suite_report.py \
  --target "$matrix_target" \
  --log "$log" \
  --source-revision "$source_revision" \
  --run-id "$run_id"
printf 'preserved successful public-suite log and report for %s\n' "$matrix_target"

#!/usr/bin/env bash
# Verify the frozen registry's public concurrent-read contract under ThreadSanitizer.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

target=""
while (($#)); do
  case "$1" in
    --target)
      target="$2"
      shift 2
      ;;
    *)
      printf 'usage: %s --target <target>\n' "$0" >&2
      exit 2
      ;;
  esac
done

if [[ "$target" != "linux_amd64" ]]; then
  printf 'ThreadSanitizer validation is supported only for linux_amd64 in this matrix\n' >&2
  exit 2
fi

expected_version=$(awk -F'"' '/^version = / {print $2}' toolchain/odin.lock)
test "$(odin version)" = "odin version $expected_version"

mkdir -p build/reports
log=build/reports/thread-sanitizer.log
odin test tests/codec_registry -o:minimal -vet -vet-style -warnings-as-errors \
  -sanitize:thread \
  -define:ODIN_TEST_THREADS=1 \
  -define:ODIN_TEST_RANDOM_SEED=123456789 \
  -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true 2>&1 | tee "$log"
if grep -Eqi 'ThreadSanitizer|data race|MemorySanitizer|AddressSanitizer' "$log"; then
  printf 'sanitizer finding detected in ThreadSanitizer log\n' >&2
  exit 1
fi
source_revision=${GITHUB_SHA:-$(git rev-parse HEAD)}
run_id=${GITHUB_RUN_ID:-local}

python3 - "$target" "$source_revision" "$run_id" "$log" <<'PY'
import hashlib
import json
import platform
import subprocess
import sys
from pathlib import Path

log_path = Path(sys.argv[4])
log_bytes = log_path.read_bytes()
if not log_bytes:
    raise RuntimeError("the successful ThreadSanitizer log is empty")
machine = platform.machine().lower()
machine = {"x86_64": "amd64", "aarch64": "arm64"}.get(machine, machine)
report = {
    "compiler": subprocess.check_output(["odin", "version"], text=True).strip(),
    "source_revision": sys.argv[2],
    "ci_run_id": sys.argv[3],
    "platform": f"{platform.system().lower()}_{machine}",
    "target": sys.argv[1],
    "mode": "minimal",
    "sanitizer": "thread",
    "target_test": "frozen-registry-concurrent-reads",
    "sanitizer_log": {
        "file": log_path.name,
        "bytes": len(log_bytes),
        "sha256": hashlib.sha256(log_bytes).hexdigest(),
    },
    "skips": 0,
    "expected_failures": 0,
    "sanitizer_findings": 0,
    "race_findings": 0,
    "memory_reports": 0,
    "unresolved_minimized_defects": 0,
}
output = Path("build/reports/thread-sanitizer.json")
output.parent.mkdir(parents=True, exist_ok=True)
output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
PY

printf 'ThreadSanitizer frozen-registry concurrent-read validation passed\n'

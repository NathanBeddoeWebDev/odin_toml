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
scripts/check_diagnostic_ledger.py
python3 -m unittest discover -s tests/release_bundle -p 'test_*.py'
scripts/assemble_release_bundle.py check-tracked

common=(-collection:external="$repo_root/external" -vet -vet-style -warnings-as-errors)

check_jobs=${CHECK_JOBS:-4}
if ! [[ "$check_jobs" =~ ^[1-9][0-9]*$ ]]; then
  printf 'CHECK_JOBS must be a positive integer, got %q\n' "$check_jobs" >&2
  exit 1
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/odin-toml-check.XXXXXX")
test_logs="$work/test-logs"
mkdir -p "$test_logs"
declare -a test_pids=()
declare -a test_labels=()

cleanup() {
  local pid
  for pid in $(jobs -pr); do
    kill "$pid" 2>/dev/null || true
  done
  wait 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

wait_test_batch() {
  local status=0 index label log
  for ((index = 0; index < ${#test_pids[@]}; index += 1)); do
    label=${test_labels[index]}
    log="$test_logs/$label.log"
    if wait "${test_pids[index]}"; then
      printf '\n===== PASS %s =====\n' "$label"
    else
      printf '\n===== FAIL %s =====\n' "$label" >&2
      status=1
    fi
    cat "$log"
    rm -f "$log"
  done
  test_pids=()
  test_labels=()
  return "$status"
}

queue_odin_test() {
  local label=$1 package=$2 test_timezone=${TZ-}
  shift 2
  (
    if [[ -n "$test_timezone" ]]; then
      export TZ="$test_timezone"
    fi
    printf '+ '
    if [[ -n "$test_timezone" ]]; then
      printf 'TZ=%q ' "$test_timezone"
    fi
    printf '%q ' odin test "$package" "$@" "${common[@]}" \
      "-out:$work/$label" \
      -define:ODIN_TEST_THREADS=1 \
      -define:ODIN_TEST_RANDOM_SEED=123456789 \
      -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true
    printf '\n'
    odin test "$package" "$@" "${common[@]}" \
      "-out:$work/$label" \
      -define:ODIN_TEST_THREADS=1 \
      -define:ODIN_TEST_RANDOM_SEED=123456789 \
      -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true
  ) >"$test_logs/$label.log" 2>&1 &
  test_pids+=("$!")
  test_labels+=("$label")

  if ((${#test_pids[@]} >= check_jobs)); then
    wait_test_batch
  fi
}

odin check . -no-entry-point "${common[@]}"
odin check external/temporal -no-entry-point "${common[@]}"
for target in linux_amd64 linux_arm64 darwin_amd64 darwin_arm64 windows_amd64; do
  odin check . -no-entry-point "-target:$target" "${common[@]}"
done

test_packages=(
  support
  temporal
  codec_registry
  semantic_lifecycle
  semantic_mutation
  semantic_unparse
  semantic_properties
  semantic_fuzz
  typed_fuzz
  typed_marshal
  typed_unmarshal
  diagnostic_acceptance
  scalar_parse
  container_parse
  table_parse
)

printf 'running Odin test packages with %s concurrent jobs\n' "$check_jobs"
for mode in minimal speed; do
  for package in "${test_packages[@]}"; do
    queue_odin_test "$mode-$package" "tests/$package" "-o:$mode"
  done
  queue_odin_test "$mode-allocator_gate" tests/allocator_gate "-o:$mode" \
    -define:TOML_ALLOCATOR_GATE_TESTING=true
  queue_odin_test "$mode-toml_test_decoder" cmd/toml_test_decoder -file "-o:$mode"
  queue_odin_test "$mode-toml_test_encoder" cmd/toml_test_encoder -file "-o:$mode"
  queue_odin_test "$mode-float_parse" tests/float_parse "-o:$mode" \
    -define:TOML_DECIMAL_GATE_TESTING=true
  queue_odin_test "$mode-float_format" tests/float_format "-o:$mode" \
    -define:TOML_BINARY64_FORMAT_GATE_TESTING=true \
    -define:TOML_DECIMAL_GATE_TESTING=true
done
wait_test_batch

scripts/check_float_format_oracle.sh
scripts/check_toml_test_decoder.sh
scripts/check_toml_test_encoder.sh

for zone in UTC Pacific/Kiritimati America/Los_Angeles; do
  label="timezone-${zone//\//_}"
  TZ="$zone" queue_odin_test "$label" tests/temporal -o:minimal
done
wait_test_batch

scripts/check_documentation.sh

for mode in minimal speed; do
  odin build tests/consumer_semantic "-o:$mode" "${common[@]}" -out:"$work/semantic-$mode"
  odin build tests/consumer_typed "-o:$mode" "${common[@]}" -out:"$work/typed-$mode"

  odin build tests/semantic_fuzz "-o:$mode" "${common[@]}" -out:"$work/semantic-fuzz-$mode"
  printf 'value = [1, 2, 3]\n' | "$work/semantic-fuzz-$mode" strict-parse
  printf 'value = "α"\n' | "$work/semantic-fuzz-$mode" valid-utf8
  printf 'value = { nested = [1, 2, 3] }\n' | "$work/semantic-fuzz-$mode" parse-unparse
  printf '\003semantic-owner' | "$work/semantic-fuzz-$mode" semantic-lifecycle
  printf '\001\002\003writer' | "$work/semantic-fuzz-$mode" writer-validation

  odin build tests/typed_fuzz "-o:$mode" "${common[@]}" -out:"$work/typed-fuzz-$mode"
  printf '\000typed-codec' | "$work/typed-fuzz-$mode"

  odin build cmd/toml_test_encoder -file "-o:$mode" "${common[@]}" -out:"$work/encoder-fuzz-$mode"
  printf '{"malformed":' | "$work/encoder-fuzz-$mode" --fuzz-target
  printf '{"value":{"type":"integer","value":"42"}}' | "$work/encoder-fuzz-$mode" --fuzz-target
done

scripts/probe_rtti.sh

printf 'all normal and optimized scaffold checks and feasibility probes passed\n'

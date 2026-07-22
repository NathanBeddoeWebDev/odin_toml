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
  odin test tests/semantic_unparse "-o:$mode" "${common[@]}" \
    -define:ODIN_TEST_THREADS=1 \
    -define:ODIN_TEST_RANDOM_SEED=123456789 \
    -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true
  odin test tests/semantic_properties "-o:$mode" "${common[@]}" \
    -define:ODIN_TEST_THREADS=1 \
    -define:ODIN_TEST_RANDOM_SEED=123456789 \
    -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true
  odin test tests/semantic_fuzz "-o:$mode" "${common[@]}" \
    -define:ODIN_TEST_THREADS=1 \
    -define:ODIN_TEST_RANDOM_SEED=123456789 \
    -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true
  odin test tests/typed_fuzz "-o:$mode" "${common[@]}" \
    -define:ODIN_TEST_THREADS=1 \
    -define:ODIN_TEST_RANDOM_SEED=123456789 \
    -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true
  odin test tests/typed_marshal "-o:$mode" "${common[@]}" \
    -define:ODIN_TEST_THREADS=1 \
    -define:ODIN_TEST_RANDOM_SEED=123456789 \
    -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true
  odin test tests/typed_unmarshal "-o:$mode" "${common[@]}" \
    -define:ODIN_TEST_THREADS=1 \
    -define:ODIN_TEST_RANDOM_SEED=123456789 \
    -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true
  odin test tests/diagnostic_acceptance "-o:$mode" "${common[@]}" \
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
  odin test cmd/toml_test_decoder -file "-o:$mode" "${common[@]}" \
    -define:ODIN_TEST_THREADS=1 \
    -define:ODIN_TEST_RANDOM_SEED=123456789 \
    -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true
  odin test cmd/toml_test_encoder -file "-o:$mode" "${common[@]}" \
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
scripts/check_toml_test_decoder.sh
scripts/check_toml_test_encoder.sh

for zone in UTC Pacific/Kiritimati America/Los_Angeles; do
  TZ="$zone" odin test tests/temporal -o:minimal "${common[@]}" \
    -define:ODIN_TEST_THREADS=1 \
    -define:ODIN_TEST_RANDOM_SEED=123456789 \
    -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true
done

scripts/check_documentation.sh

work=$(mktemp -d "${TMPDIR:-/tmp}/odin-toml-check.XXXXXX")
trap 'rm -rf "$work"' EXIT
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

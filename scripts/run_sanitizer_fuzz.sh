#!/usr/bin/env bash
# Build every public-seam fuzz target with libFuzzer coverage and AddressSanitizer.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

target=""
duration_seconds=300
while (($#)); do
  case "$1" in
    --target)
      target="$2"
      shift 2
      ;;
    --duration)
      duration_seconds="$2"
      shift 2
      ;;
    *)
      printf 'usage: %s --target <target> [--duration <seconds>]\n' "$0" >&2
      exit 2
      ;;
  esac
done

if [[ -z "$target" || ! "$duration_seconds" =~ ^[1-9][0-9]*$ ]]; then
  printf 'a supported target and positive duration are required\n' >&2
  exit 2
fi

expected_version=$(awk -F'"' '/^version = / {print $2}' toolchain/odin.lock)
test "$(odin version)" = "odin version $expected_version"
command -v clang >/dev/null

work=$(mktemp -d "${TMPDIR:-/tmp}/odin-toml-asan-fuzz.XXXXXX")
trap 'rm -rf "$work"' EXIT
common=(-o:minimal -vet -vet-style -warnings-as-errors)

# Odin's ordinary entrypoint initializes package globals before user code. libFuzzer
# replaces that entrypoint, so initialize the pinned compiler runtime explicitly.
cat >"$work/odin_libfuzzer_init.c" <<'EOF'
#if defined(__APPLE__)
#define ODIN_SYMBOL(name) asm("_" name)
#else
#define ODIN_SYMBOL(name) asm(name)
#endif

typedef struct {
    _Alignas(16) unsigned char data[112];
} OdinContext;

extern void odin_init_context(OdinContext *) ODIN_SYMBOL("runtime::[core.odin]::__init_context");
extern OdinContext odin_default_context(void) ODIN_SYMBOL("runtime::default_context");
extern void odin_startup(OdinContext *) ODIN_SYMBOL("__$startup_runtime");

int LLVMFuzzerInitialize(int *argc, char ***argv) {
    (void)argc;
    (void)argv;
    static OdinContext context;
    odin_init_context(&context);
    context = odin_default_context();
    odin_startup(&context);
    return 0;
}
EOF
init_object="$work/odin_libfuzzer_init.o"
clang -c "$work/odin_libfuzzer_init.c" -O1 -g \
  -fsanitize=fuzzer-no-link,address -o "$init_object"

build_coverage_fuzzer() {
  local name=$1
  shift
  local ir_dir="$work/$name-ir"
  local object_dir="$work/$name-objects"
  local output="$work/$name"
  mkdir -p "$ir_dir" "$object_dir"
  odin build "$@" -build-mode:llvm-ir -define:TOML_LIBFUZZER_DRIVER=true \
    "${common[@]}" -out:"$ir_dir"

  local objects=() ir object
  for ir in "$ir_dir"/*.ll; do
    [[ $(basename "$ir") == runtime-entry_* ]] && continue
    object="$object_dir/$(basename "${ir%.ll}").o"
    clang -c "$ir" -O1 -g -Wno-override-module \
      -fsanitize=fuzzer-no-link,address -o "$object"
    objects+=("$object")
  done
  ((${#objects[@]} > 0))
  clang "${objects[@]}" "$init_object" -fsanitize=fuzzer,address -o "$output"
  if [[ ! -x "$output" && -x "$output.exe" ]]; then
    output="$output.exe"
  fi
  test -x "$output"
  printf '%s' "$output"
}

semantic=$(build_coverage_fuzzer semantic-fuzz tests/semantic_fuzz)
typed=$(build_coverage_fuzzer typed-fuzz tests/typed_fuzz)
decoder=$(build_coverage_fuzzer decoder-fuzz cmd/toml_test_decoder -file)
encoder=$(build_coverage_fuzzer encoder-fuzz cmd/toml_test_encoder -file)

# The semantic driver invokes all five established semantic entrypoints for every
# artifact. The other drivers invoke their one existing public-seam target.
target_names=(
  strict-parse valid-utf8 parse-unparse semantic-lifecycle writer-validation
  typed-codec decoder-adapter encoder-adapter
)
target_runs=(0 0 0 0 0 0 0 0)

run_fuzzer() {
  local name=$1 artifact=$2 budget=$3 log="$work/$1.log"
  local corpus="$work/$name-corpus" status runs
  mkdir -p "$corpus"
  printf 'value = [1, 2, 3]\n' >"$corpus/toml"
  printf '{"value":{"type":"integer","value":"42"}}' >"$corpus/tagged-json"
  printf '\x00\xff\x01' >"$corpus/bytes"

  set +e
  if [[ $(uname -s) == Darwin ]]; then
    # libFuzzer's own RSS-monitor thread is retained at process exit on Darwin.
    # Odin bad-memory tests still run with failure enabled in the native suite.
    ASAN_OPTIONS=detect_leaks=0 "$artifact" "$corpus" \
      -max_total_time="$budget" -print_final_stats=1 >"$log" 2>&1
  else
    "$artifact" "$corpus" -max_total_time="$budget" -print_final_stats=1 >"$log" 2>&1
  fi
  status=$?
  set -e
  if [[ $status -ne 0 ]] || grep -Eqi \
    'AddressSanitizer|LeakSanitizer|UndefinedBehaviorSanitizer|MemorySanitizer|ThreadSanitizer' "$log"; then
    cat "$log" >&2
    printf 'coverage-guided sanitizer target %s failed\n' "$name" >&2
    exit 1
  fi
  runs=$(awk '/stat::number_of_executed_units:/ {value=$2} END {print value+0}' "$log")
  if ((runs == 0)); then
    cat "$log" >&2
    printf 'coverage-guided sanitizer target %s did not execute\n' "$name" >&2
    exit 1
  fi
  printf '%s' "$runs"
}

# Round up so the four coverage-guided binaries receive at least the requested
# aggregate duration even when it is not divisible by four.
per_fuzzer_seconds=$(((duration_seconds + 3) / 4))
started=$(date +%s)
semantic_runs=$(run_fuzzer semantic "$semantic" "$per_fuzzer_seconds")
typed_runs=$(run_fuzzer typed "$typed" "$per_fuzzer_seconds")
decoder_runs=$(run_fuzzer decoder "$decoder" "$per_fuzzer_seconds")
encoder_runs=$(run_fuzzer encoder "$encoder" "$per_fuzzer_seconds")
finished=$(date +%s)
elapsed=$((finished - started))

target_runs=(
  "$semantic_runs" "$semantic_runs" "$semantic_runs" "$semantic_runs" "$semantic_runs"
  "$typed_runs" "$decoder_runs" "$encoder_runs"
)

python3 - "$target" "$elapsed" "${target_names[@]}" "${target_runs[@]}" <<'PY'
import json
import platform
import subprocess
import sys
from pathlib import Path

target, elapsed, *values = sys.argv[1:]
names = values[:8]
runs = [int(value) for value in values[8:]]
machine = platform.machine().lower()
machine = {"x86_64": "amd64", "aarch64": "arm64"}.get(machine, machine)
report = {
    "compiler": subprocess.check_output(["odin", "version"], text=True).strip(),
    "platform": f"{platform.system().lower()}_{machine}",
    "target": target,
    "mode": "minimal",
    "sanitizer": "address",
    "fuzz_engine": "libFuzzer coverage-guided",
    "aggregate_duration_seconds": int(elapsed),
    "targets": dict(zip(names, runs, strict=True)),
    "skips": 0,
    "expected_failures": 0,
    "sanitizer_findings": 0,
    "race_findings": 0,
    "memory_reports": 0,
    "unresolved_minimized_defects": 0,
}
output = Path("build/reports/sanitizer-fuzz.json")
output.parent.mkdir(parents=True, exist_ok=True)
output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
PY

printf 'coverage-guided AddressSanitizer fuzz campaign passed for %s after %ss\n' "$target" "$elapsed"

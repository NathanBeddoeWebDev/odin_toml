#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

oracle=build/tools/float-format-oracle
if [[ ! -x "$oracle" ]]; then
  printf 'missing %s; run scripts/prepare_test_dependencies.sh first\n' "$oracle" >&2
  exit 1
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/odin-toml-float-format.XXXXXX")
trap 'rm -rf "$work"' EXIT

odin build tests/float_format_oracle -o:minimal -collection:external="$repo_root/external" \
  -vet -vet-style -warnings-as-errors \
  -define:TOML_BINARY64_FORMAT_GATE_TESTING=true \
  -out:"$work/format-vectors"
"$work/format-vectors" > "$work/first.tsv"
"$work/format-vectors" > "$work/second.tsv"
cmp "$work/first.tsv" "$work/second.tsv"
"$oracle" < "$work/first.tsv"

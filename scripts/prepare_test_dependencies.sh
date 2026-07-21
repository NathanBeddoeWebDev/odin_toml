#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

read_lock() {
  local file=$1 key=$2
  awk -F'"' -v key="$key" '$1 == key " = " {print $2}' "$file"
}

checkout_pin() {
  local source=$1 revision=$2 destination=$3
  if [[ -d "$destination/.git" ]]; then
    git -C "$destination" fetch --depth=1 origin "$revision"
  else
    git clone --filter=blob:none --no-checkout "$source" "$destination"
    git -C "$destination" fetch --depth=1 origin "$revision"
  fi
  git -C "$destination" checkout --detach "$revision"
  test "$(git -C "$destination" rev-parse HEAD)" = "$revision"
}

mkdir -p build/deps build/tools

toml_lock=tests/corpus/toml-test.lock
toml_source=$(read_lock "$toml_lock" source)
toml_revision=$(read_lock "$toml_lock" revision)
checkout_pin "$toml_source" "$toml_revision" build/deps/toml-test
cmp tests/corpus/toml-test.LICENSE build/deps/toml-test/LICENSE
(
  cd build/deps/toml-test
  go build -trimpath -o "$repo_root/build/tools/toml-test" ./cmd/toml-test
)

ryu_lock=tests/oracle/ryu.lock
ryu_source=$(read_lock "$ryu_lock" source)
ryu_revision=$(read_lock "$ryu_lock" revision)
checkout_pin "$ryu_source" "$ryu_revision" build/deps/ryu
cmp tests/oracle/ryu.LICENSE-Apache2 build/deps/ryu/LICENSE-Apache2
cmp tests/oracle/ryu.LICENSE-Boost build/deps/ryu/LICENSE-Boost
"${CC:-cc}" -std=c11 -O2 -Wall -Wextra -Werror \
  -I build/deps/ryu \
  build/deps/ryu/ryu/d2s.c tests/oracle/float_format_oracle.c \
  -o build/tools/float-format-oracle

printf 'prepared pinned test-only dependencies under build/\n'

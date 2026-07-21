# Test-only binary64 formatting oracle

The formatting gate compares package output with upstream Ryu from
[`ulfjack/ryu`](https://github.com/ulfjack/ryu) at commit
`4c0618b0e44f7ef027ebae05d2cc7812048f7c8f`. The exact source pin and its
Apache-2.0 / Boost-1.0 dual-license metadata are in `ryu.lock`; the unmodified
license texts are `ryu.LICENSE-Apache2` and `ryu.LICENSE-Boost`.

`scripts/prepare_test_dependencies.sh` verifies the checkout and licenses, then
builds `float_format_oracle.c` with upstream `ryu/d2s.c` as the ignored external
tool `build/tools/float-format-oracle`. `scripts/check_float_format_oracle.sh`
feeds it named raw-bit vectors and 4,096 replayable raw-bit samples. The adapter
uses Ryu only for the shortest significand and applies the approved TOML
fixed/scientific selection rule before comparison.

No oracle source, object, archive, or executable is imported, loaded, or linked
by either runtime package. The public dependency check separately verifies that
runtime dependency graph.

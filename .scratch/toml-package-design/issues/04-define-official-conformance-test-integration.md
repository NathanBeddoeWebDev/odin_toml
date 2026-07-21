# Define official TOML conformance-test integration

Type: research
Status: resolved
Blocked by: none

## Question

How does the official TOML test corpus and runner represent valid values, invalid inputs, encoder tests, version selection, and implementation integration, and what exact harness obligations should the Odin package design adopt for TOML 1.1 conformance?

## Answer

Pin canonical `toml-lang/toml-test` v2.2.0 at commit `ce08da1ddb075d1c7596d663c7fcba9a2ae02c5c` and invoke it explicitly with `-toml=1.1.0`, because its default remains TOML 1.0. Build separate test-only decoder and encoder adapters for the per-case stdin/stdout tagged-JSON protocol; successful cases must be silent on stderr, while invalid decoder input must exit exactly 1 under the pinned runner. CI requires zero valid-decoder, invalid-decoder, and encoder failures and zero undocumented skips. Preserve the JSON report and MIT attribution when redistributing fixtures. The official encoder suite checks semantic equivalence only and does not cover malformed adapter input, deterministic bytes, diagnostics, allocator behavior, limits, precision beyond milliseconds, or broad properties/fuzzing; those remain mandatory local tests.

Research asset: [Official TOML conformance-test integration](../research/toml-test-integration.md)

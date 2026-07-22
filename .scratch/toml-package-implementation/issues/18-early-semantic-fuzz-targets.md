# 18 — Early semantic fuzz targets

**What to build:** Add replayable public-seam robustness targets for parsing, UTF-8 mutation, semantic composition, lifecycle, writer validation, and conformance-adapter input.

**Blocked by:** 17 — Semantic properties and official encoder gate.

**Status:** resolved

- [x] Targets cover arbitrary strict parse, valid-UTF-8 parser mutation, and parse/unparse composition.
- [x] Targets cover semantic lifecycle and malformed-owner validation without attempting unsafe salvage destruction.
- [x] Writer targets vary count/error behavior while asserting canonical-prefix and no-retry guarantees.
- [x] Adapter targets reject malformed protocol input without panic or package leaks.
- [x] Ordinary deterministic runs execute at least 4,096 arbitrary-byte cases and 2,048 valid-seed mutations with reported replay seeds.
- [x] Accepted inputs receive semantic and canonical round-trip checks; rejected inputs remain panic-free and leak-free.
- [x] Every minimized finding becomes a deterministic public-API regression fixture.

The ordinary suite now runs replayable strict-byte, valid-UTF-8 mutation, composition, lifecycle, malformed-owner, writer, and conformance-adapter targets with observed allocation cleanup. One-artifact command entrypoints cover the five semantic target classes and tagged-JSON adapter input for later campaign orchestration. Review found and minimized a fixed 32 KiB adapter-harness sink limit; a 40,000-character accepted protocol fixture now proves replay storage scales with the artifact. The final pinned-compiler normal/speed, platform-check, bad-memory, oracle, and official TOML 1.1 conformance suite is green with replay seed `123456789`.

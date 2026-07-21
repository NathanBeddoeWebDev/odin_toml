# 18 — Early semantic fuzz targets

**What to build:** Add replayable public-seam robustness targets for parsing, UTF-8 mutation, semantic composition, lifecycle, writer validation, and conformance-adapter input.

**Blocked by:** 17 — Semantic properties and official encoder gate.

**Status:** ready-for-agent

- [ ] Targets cover arbitrary strict parse, valid-UTF-8 parser mutation, and parse/unparse composition.
- [ ] Targets cover semantic lifecycle and malformed-owner validation without attempting unsafe salvage destruction.
- [ ] Writer targets vary count/error behavior while asserting canonical-prefix and no-retry guarantees.
- [ ] Adapter targets reject malformed protocol input without panic or package leaks.
- [ ] Ordinary deterministic runs execute at least 4,096 arbitrary-byte cases and 2,048 valid-seed mutations with reported replay seeds.
- [ ] Accepted inputs receive semantic and canonical round-trip checks; rejected inputs remain panic-free and leak-free.
- [ ] Every minimized finding becomes a deterministic public-API regression fixture.

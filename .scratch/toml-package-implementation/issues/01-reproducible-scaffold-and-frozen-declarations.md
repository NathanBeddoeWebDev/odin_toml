# 01 — Reproducible scaffold and frozen declarations

**What to build:** Establish compiling public `toml` and `temporal` packages on the pinned Reference Odin revision and transcribe the complete approved public interface without changing its semantics.

**Blocked by:** None — can start immediately.

**Status:** ready-for-agent

- [ ] Both public packages and their external-consumer tests compile on the pinned compiler in normal and optimized speed modes.
- [ ] Every frozen public type, procedure family, callback, option default, attribute, and nil-success representation is present without additional public API.
- [ ] The dependency direction remains `toml` to `temporal`; the complete `toml` package documents and enforces its normal-RTTI build requirement.
- [ ] Compiler version and environment reports are reproducibly captured.
- [ ] The official TOML corpus and float oracle revisions and licenses are pinned without introducing a runtime dependency on either tool.
- [ ] Automated checks reject unintended public declarations and runtime oracle dependencies.
- [ ] Any compiler incompatibility requiring more than a syntax-only transcription adjustment is reported for design review rather than worked around by weakening the contract.

# Design review 001 — frozen typed declarations prevent RTTI-disabled package compilation

Status: open blocker

## Contract in conflict

The approved design requires the public `toml` package to retain the frozen typed API (`any` callback and marshal parameters) while semantic workflows remain compilable with RTTI disabled.

## Reproduction

On the pinned Reference Odin revision:

```text
odin version dev-2026-07:2c25fb924
```

Run:

```sh
scripts/probe_no_rtti.sh
```

The probe invokes:

```sh
odin check . -no-entry-point -target:freestanding_amd64_sysv -no-rtti \
  -vet -vet-style -warnings-as-errors
```

Reference Odin rejects the frozen declarations before a semantic consumer can compile:

```text
codecs.odin: Use of a type, any, which has been disallowed
marshal.odin: Use of a type, any, which has been disallowed
```

It also rejects unguarded `any` declarations in imported Reference Odin `core:mem` dependencies. On a hosted target, `-no-rtti` is rejected earlier because this compiler permits it only for freestanding targets or `-bedrock`; `-bedrock` additionally disables the frozen registry's map types.

## Why this is not worked around here

The available workarounds alter the approved interface or package architecture:

- omit typed declarations in RTTI-disabled builds;
- provide a reduced semantic-only package/facade;
- replace frozen `any`, `mem.Allocator`, temporal conversion, or registry declarations conditionally;
- compile with RTTI and merely define a project-local capability flag.

Those are not syntax-only transcription adjustments. The design explicitly requires escalation rather than a weakened contract, so ticket 01's RTTI-disabled acceptance item remains unresolved pending an approved design change or compiler change. Normal and optimized hosted builds are unaffected.

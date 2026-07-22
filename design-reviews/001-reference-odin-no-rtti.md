# Design review 001 — frozen typed declarations prevent RTTI-disabled package compilation

Status: resolved by approved contract change

## Resolution

The approved contract now requires normal RTTI for the complete public `toml` package. Semantic-only `ODIN_NO_RTTI` builds are unsupported because the frozen typed API retains its `any` callback and marshal parameters. The reproduction below remains as historical compiler evidence; it is no longer an acceptance gate or implementation blocker.

## Reproduction

On the pinned Reference Odin revision:

```text
odin version dev-2026-07:2c25fb924
```

Run:

```sh
scripts/probe_no_rtti.sh
```

The probe checks the external semantic consumer directly:

```sh
odin check tests/consumer_semantic -target:freestanding_amd64_sysv -no-rtti \
  -vet -vet-style -warnings-as-errors
```

Reference Odin rejects the frozen declarations before that semantic consumer can compile:

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

Those are not syntax-only transcription adjustments. The design was therefore escalated rather than worked around. The approved resolution removes RTTI-disabled package support while preserving the frozen public API, one-package architecture, semantic model, and pinned compiler.

Issue 03's RTTI-enabled mechanisms are green in minimal and optimized modes. The checked feature-to-mechanism evidence and resolved gate decision are recorded in [`rtti-feasibility-matrix.md`](rtti-feasibility-matrix.md). Reflection-dependent implementation may proceed in normal RTTI-enabled builds.

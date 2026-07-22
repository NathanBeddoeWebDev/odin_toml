# Compatibility, strictness, and non-goals

## Strict TOML contract

The package accepts exactly TOML 1.1 syntax and semantics. Keys are case-sensitive. Duplicate definitions, invalid UTF-8, recovery, replacement, extensions, TOML 1.0/legacy behavior, and permissive modes are rejected. There is no switch that weakens strict parsing or canonical validation.

Canonical output is one deterministic all-inline semantic profile. It deliberately does not reproduce source spelling or layout.

## Supported compiler, targets, and modes

The only supported compiler is the exact Reference Odin source revision and version in [`toolchain/odin.lock`](../toolchain/odin.lock). The complete root package requires normal RTTI because its frozen typed-binding declarations use `any`. `ODIN_NO_RTTI` is unsupported package-wide, including for semantic-only consumers.

The supported native release matrix is:

| Target | Normal (`-o:minimal`) | Optimized (`-o:speed`) |
| --- | --- | --- |
| `linux_amd64` | supported | supported |
| `linux_arm64` | supported | supported |
| `darwin_amd64` | supported | supported |
| `darwin_arm64` | supported | supported |
| `windows_amd64` | supported | supported |

Every matrix job enables strict vet, style, warnings-as-errors, and bad-memory failure behavior. AddressSanitizer-backed aggregate fuzz evidence is required for every listed target. ThreadSanitizer evidence for frozen-registry concurrent reads is required natively on `linux_amd64`. No compatibility or architecture support is implied for another Odin revision, target, mode, or RTTI configuration.

## Semantic-versioning policy

No release number is declared by this policy. When versions are published, the package follows SemVer classification over both declarations and documented behavior:

- a patch release fixes defects without changing public declarations, ownership and cleanup contracts, strict acceptance, canonical bytes, diagnostics, or the support matrix;
- a minor release may add backward-compatible capability without weakening existing contracts;
- a major release is required for a breaking declaration or contract change, including ownership, canonical output, strictness, diagnostics, or removal of supported compiler/target behavior.

Changing the pinned compiler or compatibility matrix is reviewed explicitly and reruns the complete release evidence suite. Performance observations do not define compatibility and do not become release thresholds without a separate approved policy.

## Non-goals

The initial package does not provide:

- CST/lossless editing or retention of comments, whitespace, source-order trivia, quote/radix/separator style, or exact fractional digit count;
- filesystem convenience APIs or streaming `io.Reader` decoding;
- permissive, recovery, duplicate-accepting, UTF-8 replacement, TOML 1.0, legacy, or extension modes;
- schema validation, configuration merging, environment expansion, or defaulting;
- public tokenizers, parser state, builders, iterators, reflected setters, path mutation, or standalone validators;
- table headers, dotted keys, or array-of-tables headers in canonical output;
- timezone database lookup, machine-local inference, broad temporal parsing/formatting, or calendar arithmetic;
- map-key codecs, raw TOML codec output, package-global registration, or callback re-entry helpers;
- generic typed destination destruction;
- compatibility promises for untested Odin revisions or targets;
- an initial benchmark pass/fail threshold.

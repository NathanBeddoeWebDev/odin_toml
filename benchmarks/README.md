# Non-gating baselines

These benchmarks are observations collected after correctness gates pass. They are not release gates, budgets, or regression thresholds. The recorder fails for a compiler mismatch, invalid fixture, public-API error, incomplete category set, or malformed output; it never fails because a measured duration or encoded size changed. Any future threshold requires a separate approved decision based on accumulated evidence.

## Reproduce performance observations

Use the pinned Reference Odin compiler and run:

```sh
scripts/record_benchmarks.py performance --output /tmp/odin-toml-performance.json
```

The driver builds with `-o:speed -vet -vet-style -warnings-as-errors`, performs one warmup and five timed samples per category, and records host/compiler provenance, operation counts, elapsed nanoseconds, and an observable checksum. Each operation releases every public owner it creates.

The committed [`baselines/performance-darwin-arm64.json`](baselines/performance-darwin-arm64.json) records one `darwin_arm64` observation for:

- strict mixed-document parse;
- semantic canonical encode from a pre-parsed document;
- typed marshal;
- typed unmarshal plus exact destination cleanup;
- late and missing lookup in a 256-entry ordered table;
- parse at 64 levels of valid nesting;
- canonical marshal of a reverse-inserted 256-entry map, including key sorting;
- a 128-element paired-codec marshal/unmarshal path through a frozen registry.

Raw timings vary with host load, hardware, and compiler environment. Compare them manually as investigative evidence only.

## Reproduce encoded-size observations

```sh
scripts/record_benchmarks.py encoded-size --output /tmp/odin-toml-inline-sizes.json
```

The committed [`baselines/inline-canonical-sizes.json`](baselines/inline-canonical-sizes.json) records source and canonical byte counts for fixed nested-table, array-of-tables, and mixed-value fixtures. The canonical profile is intentionally all-inline, so the observations expose its size tradeoff. Fixture hashes and canonical checksums make each observation reviewable; no size has a pass/fail threshold.

The fixed source inputs live under [`fixtures/`](fixtures/). `scripts/assemble_release_bundle.py check-tracked` checks that the recorded schema, fixture hashes, compiler revision, and required categories are complete. It does not re-measure or compare performance and does not impose a size limit.

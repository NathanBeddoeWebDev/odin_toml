#!/usr/bin/env python3
"""Record non-gating public-API performance or canonical-size observations."""

from __future__ import annotations

import argparse
import hashlib
import json
import platform
import statistics
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REQUIRED_BENCHMARKS = [
    "parse",
    "semantic-encode",
    "typed-marshal",
    "typed-unmarshal",
    "ordered-table",
    "depth",
    "map-sort",
    "codec-heavy",
]
SIZE_FIXTURES = {
    "nested-tables": ROOT / "benchmarks/fixtures/size-nested.toml",
    "arrays-of-tables": ROOT / "benchmarks/fixtures/size-aot.toml",
    "mixed-values": ROOT / "benchmarks/fixtures/size-mixed.toml",
}


def lock_value(name: str) -> str:
    for line in (ROOT / "toolchain/odin.lock").read_text().splitlines():
        if line.startswith(f"{name} = "):
            return line.split('"', 2)[1]
    raise RuntimeError(f"missing {name} in toolchain/odin.lock")


def verify_compiler() -> str:
    actual = subprocess.check_output(["odin", "version"], text=True).strip()
    expected = f"odin version {lock_value('version')}"
    if actual != expected:
        raise RuntimeError(f"expected {expected}, got {actual}")
    return actual


def host_record() -> dict[str, str]:
    return {
        "platform": platform.system().lower(),
        "architecture": platform.machine().lower(),
        "processor": platform.processor() or "unknown",
        "python": platform.python_version(),
    }


def run_driver(mode: str) -> tuple[str, list[str]]:
    command = [
        "odin",
        "build",
        "benchmarks",
        "-o:speed",
        "-vet",
        "-vet-style",
        "-warnings-as-errors",
    ]
    with tempfile.TemporaryDirectory(prefix="odin-toml-benchmarks-") as directory:
        executable = Path(directory) / "benchmarks"
        subprocess.run(
            [*command, f"-out:{executable}"], cwd=ROOT, check=True
        )
        output = subprocess.check_output([executable, mode], cwd=ROOT, text=True)
    return output, command


def parse_rows(output: str, kind: str, width: int) -> list[list[str]]:
    rows = []
    for line in output.splitlines():
        fields = line.split("\t")
        if len(fields) != width or fields[0] != kind:
            raise RuntimeError(f"unexpected benchmark-driver output: {line!r}")
        rows.append(fields)
    if not rows:
        raise RuntimeError("benchmark driver produced no observations")
    return rows


def performance_report(compiler: str, output: str, command: list[str]) -> dict:
    grouped: dict[str, list[tuple[int, int, int]]] = {}
    for _, name, operations, elapsed, checksum in parse_rows(output, "benchmark", 5):
        observation = (int(operations), int(elapsed), int(checksum))
        if observation[0] <= 0 or observation[1] <= 0:
            raise RuntimeError(f"non-positive observation for {name}")
        grouped.setdefault(name, []).append(observation)
    if list(grouped) != REQUIRED_BENCHMARKS:
        raise RuntimeError(
            f"expected benchmark categories {REQUIRED_BENCHMARKS}, got {list(grouped)}"
        )

    results = []
    for name in REQUIRED_BENCHMARKS:
        observations = grouped[name]
        operations = {item[0] for item in observations}
        checksums = {item[2] for item in observations}
        if len(observations) != 5 or len(operations) != 1 or len(checksums) != 1:
            raise RuntimeError(f"inconsistent samples for {name}")
        operation_count = operations.pop()
        elapsed_ns = [item[1] for item in observations]
        results.append(
            {
                "name": name,
                "operations_per_sample": operation_count,
                "elapsed_ns_samples": elapsed_ns,
                "median_ns_per_operation": statistics.median(elapsed_ns)
                / operation_count,
                "checksum": checksums.pop(),
            }
        )

    return {
        "schema": 1,
        "kind": "performance-observations",
        "release_gating": False,
        "policy": "Recorded observations only; no thresholds or pass/fail comparisons.",
        "compiler": compiler,
        "compiler_revision": lock_value("revision"),
        "host": host_record(),
        "reproduce": [*command, "-out:<temporary>/benchmarks", "&&", "<temporary>/benchmarks", "performance"],
        "methodology": {
            "build_mode": "speed",
            "warmups_per_category": 1,
            "samples_per_category": 5,
            "timing": "monotonic elapsed nanoseconds",
            "cleanup": "each operation releases every public-API owner it creates",
        },
        "results": results,
    }


def encoded_size_report(compiler: str, output: str, command: list[str]) -> dict:
    rows = parse_rows(output, "size", 5)
    if [row[1] for row in rows] != list(SIZE_FIXTURES):
        raise RuntimeError("encoded-size fixture set is incomplete or out of order")
    results = []
    for _, name, source_bytes, canonical_bytes, checksum in rows:
        fixture = SIZE_FIXTURES[name]
        source = fixture.read_bytes()
        if len(source) != int(source_bytes) or int(canonical_bytes) <= 0:
            raise RuntimeError(f"invalid size observation for {name}")
        results.append(
            {
                "name": name,
                "fixture": fixture.relative_to(ROOT).as_posix(),
                "fixture_sha256": hashlib.sha256(source).hexdigest(),
                "source_bytes": len(source),
                "canonical_bytes": int(canonical_bytes),
                "canonical_fnv1a64": int(checksum),
                "expansion_ratio": int(canonical_bytes) / len(source),
            }
        )
    return {
        "schema": 1,
        "kind": "inline-canonical-size-observations",
        "profile": "all-inline canonical TOML",
        "release_gating": False,
        "policy": "Recorded encoded sizes only; no thresholds or pass/fail comparisons.",
        "compiler": compiler,
        "compiler_revision": lock_value("revision"),
        "reproduce": [*command, "-out:<temporary>/benchmarks", "&&", "<temporary>/benchmarks", "encoded-size"],
        "results": results,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="mode", required=True)
    for mode in ("performance", "encoded-size"):
        subparser = subparsers.add_parser(mode)
        subparser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    compiler = verify_compiler()
    output, command = run_driver(args.mode)
    if args.mode == "performance":
        report = performance_report(compiler, output, command)
    else:
        report = encoded_size_report(compiler, output, command)
    destination = args.output
    if not destination.is_absolute():
        destination = ROOT / destination
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(f"wrote non-gating {args.mode} observations to {destination}")


if __name__ == "__main__":
    main()

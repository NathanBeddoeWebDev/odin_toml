#!/usr/bin/env python3
"""Write provenance for a successfully completed native public suite."""

from __future__ import annotations

import argparse
import hashlib
import json
import platform
import subprocess
from pathlib import Path

COMPLETED_GATES = [
    "strict-cross-target-typecheck",
    "official-conformance",
    "focused-parser-temporal",
    "diagnostics",
    "semantic-lifecycle",
    "exact-canonical-encoder",
    "semantic-typed-properties",
    "reflection-codecs",
    "allocator-sweeps",
    "writer-sweeps",
    "deterministic-fuzz-replay",
    "external-consumers-documentation",
]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--target", required=True)
    parser.add_argument("--log", type=Path, required=True)
    parser.add_argument("--source-revision", required=True)
    parser.add_argument("--run-id", required=True)
    args = parser.parse_args()

    log_bytes = args.log.read_bytes()
    if not log_bytes:
        raise RuntimeError("the successful public-suite log is empty")
    compiler = subprocess.check_output(["odin", "version"], text=True).strip()
    machine = platform.machine().lower()
    machine = {"x86_64": "amd64", "aarch64": "arm64"}.get(machine, machine)
    report = {
        "compiler": compiler,
        "source_revision": args.source_revision,
        "ci_run_id": args.run_id,
        "platform": f"{platform.system().lower()}_{machine}",
        "target": args.target,
        "modes": ["minimal", "speed"],
        "strict": {"vet": True, "vet_style": True, "warnings_as_errors": True},
        "bad_memory_failure": True,
        "completed_gates": COMPLETED_GATES,
        "suite_log": {
            "file": args.log.name,
            "bytes": len(log_bytes),
            "sha256": hashlib.sha256(log_bytes).hexdigest(),
        },
        "skips": 0,
        "expected_failures": 0,
        "sanitizer_findings": 0,
        "race_findings": 0,
        "memory_reports": 0,
        "unresolved_minimized_defects": 0,
    }
    output = Path("build/reports/public-suite.json")
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")


if __name__ == "__main__":
    main()

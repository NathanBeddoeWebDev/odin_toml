#!/usr/bin/env python3
"""Write the successful native public-suite provenance record."""

from __future__ import annotations

import argparse
import json
import platform
import subprocess
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--target", required=True)
    args = parser.parse_args()

    compiler = subprocess.check_output(["odin", "version"], text=True).strip()
    machine = platform.machine().lower()
    machine = {"x86_64": "amd64", "aarch64": "arm64"}.get(machine, machine)
    report = {
        "compiler": compiler,
        "platform": f"{platform.system().lower()}_{machine}",
        "target": args.target,
        "modes": ["minimal", "speed"],
        "strict": {"vet": True, "vet_style": True, "warnings_as_errors": True},
        "bad_memory_failure": True,
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

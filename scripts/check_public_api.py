#!/usr/bin/env python3
"""Reject drift from the approved public TOML and temporal declarations."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PACKAGES = {
    "toml": (ROOT, ROOT / "api" / "toml.public-api"),
    "temporal": (ROOT / "temporal", ROOT / "api" / "temporal.public-api"),
}
REQUIRE_RESULTS = {
    "toml": {
        "clone_document",
        "clone_value",
        "get",
        "init_codec_registry",
        "marshal",
        "marshal_to_writer",
        "parse_bytes",
        "parse_string",
        "register_marshaler",
        "register_unmarshaler",
        "remove",
        "set",
        "unmarshal",
        "unmarshal_string",
        "unparse",
        "unparse_to_writer",
    },
    "temporal": {
        "compare_instant",
        "compare_local_date",
        "compare_local_date_time",
        "compare_local_time",
        "local_date_from_datetime",
        "local_date_time_from_datetime",
        "local_date_time_to_datetime",
        "local_date_to_datetime",
        "local_time_from_datetime",
        "local_time_to_datetime",
        "offset_date_time_from_time",
        "offset_date_time_from_time_utc",
        "offset_date_time_to_time",
        "validate_local_date",
        "validate_local_date_time",
        "validate_local_time",
        "validate_offset_date_time",
        "validate_utc_offset",
    },
}
SOURCE_LOCATION = re.compile(r" /\* \d+!\d+ \*/")


def documented_api(package_dir: Path) -> str:
    result = subprocess.run(
        ["odin", "doc", str(package_dir)],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
    )
    if result.returncode:
        raise SystemExit(result.stdout + result.stderr)
    public = result.stdout.split("\n\tfullpath:\n", 1)[0].rstrip() + "\n"
    return SOURCE_LOCATION.sub("", public)


def check_require_results(package: str, package_dir: Path) -> list[str]:
    source = "\n".join(path.read_text() for path in sorted(package_dir.glob("*.odin")))
    attributed = set(re.findall(r"@\(require_results\)\s+(\w+)\s+::\s+proc\b", source))
    expected = REQUIRE_RESULTS[package]
    failures = []
    missing = sorted(expected - attributed)
    extra = sorted(attributed - expected)
    if missing:
        failures.append(f"{package} procedures missing @(require_results): {', '.join(missing)}")
    if extra:
        failures.append(f"{package} procedures unexpectedly use @(require_results): {', '.join(extra)}")
    return failures


def check_runtime_dependencies() -> list[str]:
    failures = []
    forbidden = ("foreign import", "toml-test", "ulfjack", "ryu", "tests/oracle", "tests/corpus")
    for package_dir, _ in PACKAGES.values():
        for path in sorted(package_dir.glob("*.odin")):
            lowered = path.read_text().lower()
            for marker in forbidden:
                if marker in lowered:
                    failures.append(f"{path.relative_to(ROOT)} contains forbidden runtime marker {marker!r}")

    temporal_source = "\n".join(path.read_text() for path in sorted((ROOT / "temporal").glob("*.odin")))
    if re.search(r'^\s*import(?:\s+\w+)?\s+"(?:\.\./)?toml"', temporal_source, re.MULTILINE):
        failures.append("temporal must not import toml")

    with tempfile.TemporaryDirectory(prefix="odin-toml-deps-") as temporary:
        dependency_file = Path(temporary) / "dependencies.json"
        executable = Path(temporary) / "consumer"
        result = subprocess.run(
            [
                "odin",
                "build",
                "tests/consumer_semantic",
                f"-out:{executable}",
                "-export-dependencies:json",
                f"-export-dependencies-file:{dependency_file}",
            ],
            cwd=ROOT,
            text=True,
            capture_output=True,
            check=False,
        )
        if result.returncode:
            failures.append("could not export the runtime dependency graph: " + result.stdout + result.stderr)
            return failures
        dependencies = json.loads(dependency_file.read_text())

    odin_root_result = subprocess.run(
        ["odin", "root"], cwd=ROOT, text=True, capture_output=True, check=True
    )
    odin_root = Path(odin_root_result.stdout.strip()).resolve()
    for source_file in dependencies["source_files"]:
        path = Path(source_file).resolve()
        if not path.is_relative_to(ROOT) and not path.is_relative_to(odin_root):
            failures.append(f"runtime source dependency is outside the project and pinned Odin tree: {path}")
        lowered = path.as_posix().lower()
        if any(marker in lowered for marker in forbidden[1:]):
            failures.append(f"runtime dependency graph contains forbidden oracle path: {path}")
    for load_file in dependencies["load_files"]:
        lowered = str(load_file).lower()
        if any(marker in lowered for marker in forbidden[1:]):
            failures.append(f"runtime dependency graph contains forbidden oracle load: {load_file}")
    return failures


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--update", action="store_true", help="rewrite frozen API snapshots")
    args = parser.parse_args()

    failures = []
    for package, (package_dir, golden_path) in PACKAGES.items():
        actual = documented_api(package_dir)
        if args.update:
            golden_path.parent.mkdir(parents=True, exist_ok=True)
            golden_path.write_text(actual)
        elif not golden_path.exists() or actual != golden_path.read_text():
            failures.append(f"{package} public API differs from {golden_path.relative_to(ROOT)}")
        failures.extend(check_require_results(package, package_dir))

    failures.extend(check_runtime_dependencies())
    if failures:
        print("public API check failed:")
        for failure in failures:
            print(f"- {failure}")
        if not args.update:
            print("Run with --update only after approved interface review.")
        return 1
    print("public API and runtime dependency checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

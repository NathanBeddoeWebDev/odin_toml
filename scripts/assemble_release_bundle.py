#!/usr/bin/env python3
"""Validate and assemble the complete release-candidate evidence bundle."""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
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
REQUIRED_SIZE_FIXTURES = ["nested-tables", "arrays-of-tables", "mixed-values"]


class Bundle_Error(RuntimeError):
    pass


def load_json(path: Path) -> dict:
    try:
        value = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise Bundle_Error(f"cannot read JSON evidence {path}: {error}") from error
    if not isinstance(value, dict):
        raise Bundle_Error(f"JSON evidence must be an object: {path}")
    return value


def lock_values(path: Path) -> dict[str, object]:
    values: dict[str, object] = {}
    for line in path.read_text().splitlines():
        if " = " not in line:
            continue
        name, raw = line.split(" = ", 1)
        if raw.startswith('"') and raw.endswith('"'):
            values[name] = raw[1:-1]
        elif raw in ("true", "false"):
            values[name] = raw == "true"
        elif raw.startswith("["):
            values[name] = [part.strip().strip('"') for part in raw[1:-1].split(",")]
    return values


def require_equal(actual: object, expected: object, label: str) -> None:
    if actual != expected:
        raise Bundle_Error(f"{label}: expected {expected!r}, got {actual!r}")


def require_zero_counters(report: dict, counters: list[str], label: str) -> None:
    for counter in counters:
        if report.get(counter) != 0:
            raise Bundle_Error(
                f"{label} has unresolved {counter}: expected 0, got {report.get(counter)!r}"
            )


def validate_provenance(
    report: dict, source_revision: str, run_id: str, label: str
) -> None:
    require_equal(report.get("source_revision"), source_revision, f"{label} source revision")
    require_equal(report.get("ci_run_id"), run_id, f"{label} CI run ID")


def validate_preserved_log(
    report: dict, field: str, report_path: Path, label: str
) -> Path:
    metadata = report.get(field)
    if not isinstance(metadata, dict):
        raise Bundle_Error(f"{label} is missing preserved log metadata")
    file_name = metadata.get("file")
    if not isinstance(file_name, str) or Path(file_name).name != file_name:
        raise Bundle_Error(f"{label} has an invalid preserved log name")
    log_path = report_path.parent / file_name
    try:
        log_bytes = log_path.read_bytes()
    except OSError as error:
        raise Bundle_Error(f"{label} preserved log is missing: {log_path}") from error
    require_equal(len(log_bytes), metadata.get("bytes"), f"{label} log bytes")
    require_equal(
        hashlib.sha256(log_bytes).hexdigest(),
        metadata.get("sha256"),
        f"{label} log SHA-256",
    )
    return log_path


def reject_threshold_keys(value: object, location: str = "baseline") -> None:
    if isinstance(value, dict):
        for key, child in value.items():
            if "threshold" in key.lower():
                raise Bundle_Error(f"{location} contains forbidden performance threshold field {key!r}")
            reject_threshold_keys(child, f"{location}.{key}")
    elif isinstance(value, list):
        for index, child in enumerate(value):
            reject_threshold_keys(child, f"{location}[{index}]")


def validate_performance_baseline(report: dict) -> None:
    reject_threshold_keys(report, "performance baseline")
    require_equal(report.get("kind"), "performance-observations", "performance kind")
    require_equal(report.get("release_gating"), False, "performance release_gating")
    names = [item.get("name") for item in report.get("results", [])]
    if names != REQUIRED_BENCHMARKS:
        missing = [name for name in REQUIRED_BENCHMARKS if name not in names]
        raise Bundle_Error(
            f"performance baseline categories are incomplete; missing {', '.join(missing) or 'none'}"
        )
    for item in report["results"]:
        samples = item.get("elapsed_ns_samples")
        if not isinstance(samples, list) or not samples or any(
            not isinstance(sample, int) or sample <= 0 for sample in samples
        ):
            raise Bundle_Error(f"invalid elapsed samples for {item.get('name')}")
        if item.get("operations_per_sample", 0) <= 0:
            raise Bundle_Error(f"invalid operation count for {item.get('name')}")


def validate_encoded_size_baseline(report: dict, repo_root: Path) -> None:
    reject_threshold_keys(report, "encoded-size baseline")
    require_equal(
        report.get("kind"),
        "inline-canonical-size-observations",
        "encoded-size kind",
    )
    require_equal(report.get("release_gating"), False, "encoded-size release_gating")
    results = report.get("results", [])
    names = [item.get("name") for item in results]
    require_equal(names, REQUIRED_SIZE_FIXTURES, "encoded-size fixtures")
    for item in results:
        fixture = repo_root / item.get("fixture", "")
        if not fixture.is_file():
            raise Bundle_Error(f"missing encoded-size fixture {fixture}")
        source = fixture.read_bytes()
        require_equal(len(source), item.get("source_bytes"), f"{fixture} source bytes")
        require_equal(
            hashlib.sha256(source).hexdigest(),
            item.get("fixture_sha256"),
            f"{fixture} SHA-256",
        )
        if item.get("canonical_bytes", 0) <= 0:
            raise Bundle_Error(f"invalid canonical byte count for {fixture}")


def validate_tracked(manifest_path: Path, repo_root: Path = ROOT) -> dict:
    manifest = load_json(manifest_path)
    require_equal(manifest.get("schema"), 1, "release manifest schema")

    compiler_lock = lock_values(repo_root / manifest["compiler"]["lock"])
    for key in ("source", "revision", "version"):
        require_equal(compiler_lock.get(key), manifest["compiler"][key], f"compiler {key}")

    for dependency_name in ("toml_test", "float_oracle"):
        dependency = manifest["dependencies"][dependency_name]
        lock = lock_values(repo_root / dependency["lock"])
        for key in ("source", "revision"):
            require_equal(lock.get(key), dependency[key], f"{dependency_name} {key}")
        for key in ("tag", "toml_version"):
            if key in dependency:
                require_equal(lock.get(key), dependency[key], f"{dependency_name} {key}")

    compiler_version = manifest["compiler"]["version"]
    toml_dependency = manifest["dependencies"]["toml_test"]
    for entry in manifest["conformance"]:
        report = load_json(repo_root / entry["report"])
        provenance = report.get("provenance", {})
        require_equal(provenance.get("odin"), compiler_version, f"{entry['kind']} compiler")
        require_equal(provenance.get("source"), toml_dependency["source"], f"{entry['kind']} source")
        require_equal(provenance.get("revision"), toml_dependency["revision"], f"{entry['kind']} revision")
        require_equal(report.get("result", {}).get("toml"), toml_dependency["toml_version"], f"{entry['kind']} TOML version")
        result = report["result"]
        for count in ("passed_valid", "passed_invalid", "passed_encoder"):
            require_equal(result.get(count), entry[count], f"{entry['kind']} {count}")
        for count in ("failed_valid", "failed_invalid", "failed_encoder", "skipped"):
            require_equal(result.get(count), 0, f"{entry['kind']} {count}")

    performance = load_json(repo_root / manifest["baselines"]["performance"])
    encoded_size = load_json(repo_root / manifest["baselines"]["encoded_size"])
    validate_performance_baseline(performance)
    validate_encoded_size_baseline(encoded_size, repo_root)
    require_equal(manifest["baselines"].get("release_gating"), False, "manifest baselines release_gating")
    require_equal(performance.get("compiler_revision"), manifest["compiler"]["revision"], "performance compiler revision")
    require_equal(encoded_size.get("compiler_revision"), manifest["compiler"]["revision"], "encoded-size compiler revision")

    expected_targets = manifest["support"]["targets"]
    require_equal(manifest["sanitizers"]["address"]["targets"], expected_targets, "AddressSanitizer targets")
    if set(manifest["zero_tolerance_counters"]) != {
        "skips",
        "expected_failures",
        "sanitizer_findings",
        "race_findings",
        "memory_reports",
        "unresolved_minimized_defects",
    }:
        raise Bundle_Error("release manifest zero-tolerance counter set is incomplete")
    require_equal(manifest["generated_testing"].get("minimized_defect_count"), 0, "minimized defects")
    require_equal(
        list(manifest.get("acceptance_gate_sources", {})),
        manifest["acceptance_gates"],
        "acceptance-gate source ledger",
    )
    for gate, sources in manifest["acceptance_gate_sources"].items():
        if not sources:
            raise Bundle_Error(f"acceptance gate {gate} has no evidence source")
        for relative in sources:
            if not (repo_root / relative).exists():
                raise Bundle_Error(f"acceptance gate {gate} is missing source {relative}")

    for relative in manifest["tracked_bundle_files"]:
        if not (repo_root / relative).is_file():
            raise Bundle_Error(f"missing tracked bundle member {relative}")
    return manifest


def validate_platform_report(
    report: dict,
    report_path: Path,
    target: str,
    manifest: dict,
    source_revision: str,
    run_id: str,
) -> Path:
    validate_provenance(report, source_revision, run_id, f"{target} public suite")
    require_equal(report.get("compiler"), f"odin version {manifest['compiler']['version']}", f"{target} compiler")
    require_equal(report.get("target"), target, f"{target} target")
    require_equal(report.get("platform"), target, f"{target} native platform")
    require_equal(report.get("modes"), manifest["support"]["modes"], f"{target} modes")
    require_equal(report.get("strict"), manifest["support"]["strict"], f"{target} strict flags")
    require_equal(report.get("bad_memory_failure"), True, f"{target} bad-memory mode")
    require_equal(
        report.get("completed_gates"),
        manifest["acceptance_gates"],
        f"{target} completed acceptance gates",
    )
    require_zero_counters(report, manifest["zero_tolerance_counters"], f"{target} public suite")
    return validate_preserved_log(report, "suite_log", report_path, f"{target} public suite")


def validate_sanitizer_report(
    report: dict,
    report_path: Path,
    target: str,
    manifest: dict,
    source_revision: str,
    run_id: str,
) -> Path:
    validate_provenance(report, source_revision, run_id, f"{target} sanitizer")
    require_equal(report.get("compiler"), f"odin version {manifest['compiler']['version']}", f"{target} sanitizer compiler")
    require_equal(report.get("target"), target, f"{target} sanitizer target")
    require_equal(report.get("platform"), target, f"{target} sanitizer native platform")
    require_equal(report.get("sanitizer"), "address", f"{target} sanitizer")
    require_equal(report.get("fuzz_engine"), manifest["sanitizers"]["address"]["fuzz_engine"], f"{target} fuzz engine")
    minimum = manifest["sanitizers"]["address"]["aggregate_duration_seconds_minimum"]
    if report.get("aggregate_duration_seconds", 0) < minimum:
        raise Bundle_Error(f"{target} sanitizer campaign must run at least {minimum} seconds")
    required_targets = manifest["generated_testing"]["fuzz_targets"]
    runs = report.get("targets", {})
    require_equal(list(runs), required_targets, f"{target} fuzz target set")
    if any(not isinstance(runs[name], int) or runs[name] <= 0 for name in required_targets):
        raise Bundle_Error(f"{target} sanitizer evidence contains an unexecuted target")
    require_zero_counters(report, manifest["zero_tolerance_counters"], f"{target} sanitizer")
    return validate_preserved_log(
        report, "campaign_log", report_path, f"{target} sanitizer"
    )


def validate_thread_report(
    report: dict,
    report_path: Path,
    manifest: dict,
    source_revision: str,
    run_id: str,
) -> Path:
    validate_provenance(report, source_revision, run_id, "ThreadSanitizer")
    contract = manifest["sanitizers"]["thread"]
    target = contract["target"]
    require_equal(report.get("compiler"), f"odin version {manifest['compiler']['version']}", "ThreadSanitizer compiler")
    require_equal(report.get("target"), target, "ThreadSanitizer target")
    require_equal(report.get("platform"), target, "ThreadSanitizer native platform")
    require_equal(report.get("sanitizer"), "thread", "ThreadSanitizer kind")
    require_equal(report.get("target_test"), contract["test"], "ThreadSanitizer test")
    require_zero_counters(report, manifest["zero_tolerance_counters"], "ThreadSanitizer")
    return validate_preserved_log(
        report, "sanitizer_log", report_path, "ThreadSanitizer"
    )


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def assemble(
    *,
    manifest_path: Path,
    reports_root: Path,
    output: Path,
    source_revision: str,
    run_id: str,
    repo_root: Path = ROOT,
) -> dict:
    manifest = validate_tracked(manifest_path, repo_root)
    evidence: list[tuple[Path, Path]] = []
    prefix = manifest["ci_evidence"]["platform_artifact_prefix"]
    for target in manifest["support"]["targets"]:
        artifact = f"{prefix}{target}"
        directory = reports_root / artifact
        public_path = directory / "public-suite.json"
        sanitizer_path = directory / "sanitizer-fuzz.json"
        public = load_json(public_path)
        sanitizer = load_json(sanitizer_path)
        public_log = validate_platform_report(
            public, public_path, target, manifest, source_revision, run_id
        )
        sanitizer_log = validate_sanitizer_report(
            sanitizer, sanitizer_path, target, manifest, source_revision, run_id
        )
        evidence.extend(
            [
                (public_path, Path("ci") / artifact / public_path.name),
                (public_log, Path("ci") / artifact / public_log.name),
                (sanitizer_path, Path("ci") / artifact / sanitizer_path.name),
                (sanitizer_log, Path("ci") / artifact / sanitizer_log.name),
            ]
        )

    thread_artifact = manifest["ci_evidence"]["thread_artifact"]
    thread_path = reports_root / thread_artifact / "thread-sanitizer.json"
    thread_log = validate_thread_report(
        load_json(thread_path), thread_path, manifest, source_revision, run_id
    )
    evidence.extend(
        [
            (thread_path, Path("ci") / thread_artifact / thread_path.name),
            (thread_log, Path("ci") / thread_artifact / thread_log.name),
        ]
    )

    if output.exists() and any(output.iterdir()):
        raise Bundle_Error(f"release bundle output is not empty: {output}")
    output.mkdir(parents=True, exist_ok=True)
    members = []
    for relative in manifest["tracked_bundle_files"]:
        source = repo_root / relative
        destination_relative = Path("tracked") / relative
        destination = output / destination_relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, destination)
        members.append(
            {"path": destination_relative.as_posix(), "sha256": sha256(destination)}
        )
    for source, destination_relative in evidence:
        destination = output / destination_relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, destination)
        members.append(
            {"path": destination_relative.as_posix(), "sha256": sha256(destination)}
        )
    members.sort(key=lambda item: item["path"])
    resolved = {
        "schema": 1,
        "source_revision": source_revision,
        "ci_run_id": run_id,
        "manifest": "tracked/release/manifest.json",
        "zero_tolerance_verified": True,
        "performance_gating": False,
        "members": members,
    }
    (output / "resolved-manifest.json").write_text(
        json.dumps(resolved, indent=2, sort_keys=True) + "\n"
    )
    return resolved


def main() -> None:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    check_parser = subparsers.add_parser("check-tracked")
    check_parser.add_argument("--manifest", type=Path, default=ROOT / "release/manifest.json")
    assemble_parser = subparsers.add_parser("assemble")
    assemble_parser.add_argument("--manifest", type=Path, default=ROOT / "release/manifest.json")
    assemble_parser.add_argument("--reports-root", type=Path, required=True)
    assemble_parser.add_argument("--output", type=Path, required=True)
    assemble_parser.add_argument("--source-revision", required=True)
    assemble_parser.add_argument("--run-id", required=True)
    args = parser.parse_args()
    try:
        if args.command == "check-tracked":
            validate_tracked(args.manifest)
            print("tracked release manifest and non-gating baselines are valid")
        else:
            resolved = assemble(
                manifest_path=args.manifest,
                reports_root=args.reports_root,
                output=args.output,
                source_revision=args.source_revision,
                run_id=args.run_id,
            )
            print(f"assembled {len(resolved['members'])} reviewed release evidence members")
    except Bundle_Error as error:
        parser.error(str(error))


if __name__ == "__main__":
    main()

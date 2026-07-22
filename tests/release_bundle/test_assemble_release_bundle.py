#!/usr/bin/env python3
from __future__ import annotations

import copy
import hashlib
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "assemble_release_bundle", ROOT / "scripts/assemble_release_bundle.py"
)
assert SPEC is not None and SPEC.loader is not None
bundle = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(bundle)

TARGETS = [
    "linux_amd64",
    "linux_arm64",
    "darwin_amd64",
    "darwin_arm64",
    "windows_amd64",
]
COMPILER = "odin version dev-2026-07:2c25fb924"
SOURCE_REVISION = "0123456789abcdef"
RUN_ID = "1234"
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
ZEROES = {
    "skips": 0,
    "expected_failures": 0,
    "sanitizer_findings": 0,
    "race_findings": 0,
    "memory_reports": 0,
    "unresolved_minimized_defects": 0,
}


def log_metadata(file_name: str, content: bytes) -> dict:
    return {
        "file": file_name,
        "bytes": len(content),
        "sha256": hashlib.sha256(content).hexdigest(),
    }


def public_report(target: str, log: bytes) -> dict:
    return {
        "compiler": COMPILER,
        "source_revision": SOURCE_REVISION,
        "ci_run_id": RUN_ID,
        "platform": target,
        "target": target,
        "modes": ["minimal", "speed"],
        "strict": {"vet": True, "vet_style": True, "warnings_as_errors": True},
        "bad_memory_failure": True,
        "completed_gates": COMPLETED_GATES,
        "suite_log": log_metadata("public-suite.log", log),
        **ZEROES,
    }


def sanitizer_report(target: str, log: bytes) -> dict:
    return {
        "compiler": COMPILER,
        "source_revision": SOURCE_REVISION,
        "ci_run_id": RUN_ID,
        "platform": target,
        "target": target,
        "mode": "minimal",
        "sanitizer": "address",
        "fuzz_engine": "libFuzzer coverage-guided",
        "aggregate_duration_seconds": 300,
        "targets": {
            "strict-parse": 1,
            "valid-utf8": 1,
            "parse-unparse": 1,
            "semantic-lifecycle": 1,
            "writer-validation": 1,
            "typed-codec": 1,
            "decoder-adapter": 1,
            "encoder-adapter": 1,
        },
        "campaign_log": log_metadata("sanitizer-fuzz.log", log),
        **ZEROES,
    }


def thread_report(log: bytes) -> dict:
    return {
        "compiler": COMPILER,
        "source_revision": SOURCE_REVISION,
        "ci_run_id": RUN_ID,
        "platform": "linux_amd64",
        "target": "linux_amd64",
        "mode": "minimal",
        "sanitizer": "thread",
        "target_test": "frozen-registry-concurrent-reads",
        "sanitizer_log": log_metadata("thread-sanitizer.log", log),
        **ZEROES,
    }


class ReleaseBundleTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.reports = self.directory / "reports"
        self.output = self.directory / "bundle"
        for target in TARGETS:
            target_directory = self.reports / f"reports-{target}"
            target_directory.mkdir(parents=True)
            public_log = f"successful public suite for {target}\n".encode()
            sanitizer_log = f"successful sanitizer campaign for {target}\n".encode()
            (target_directory / "public-suite.log").write_bytes(public_log)
            (target_directory / "sanitizer-fuzz.log").write_bytes(sanitizer_log)
            (target_directory / "public-suite.json").write_text(
                json.dumps(public_report(target, public_log))
            )
            (target_directory / "sanitizer-fuzz.json").write_text(
                json.dumps(sanitizer_report(target, sanitizer_log))
            )
        thread_directory = self.reports / "reports-linux-amd64-thread-sanitizer"
        thread_directory.mkdir(parents=True)
        thread_log = b"successful ThreadSanitizer suite\n"
        (thread_directory / "thread-sanitizer.log").write_bytes(thread_log)
        (thread_directory / "thread-sanitizer.json").write_text(
            json.dumps(thread_report(thread_log))
        )

    def assemble(self) -> dict:
        return bundle.assemble(
            manifest_path=ROOT / "release/manifest.json",
            reports_root=self.reports,
            output=self.output,
            source_revision=SOURCE_REVISION,
            run_id=RUN_ID,
            repo_root=ROOT,
        )

    def test_complete_native_evidence_is_hashed_into_bundle(self) -> None:
        resolved = self.assemble()
        self.assertEqual(resolved["source_revision"], SOURCE_REVISION)
        manifest = json.loads((ROOT / "release/manifest.json").read_text())
        self.assertEqual(
            len(resolved["members"]), len(manifest["tracked_bundle_files"]) + 22
        )
        self.assertTrue((self.output / "resolved-manifest.json").is_file())
        self.assertTrue(
            (
                self.output
                / "ci/reports-linux_amd64/public-suite.json"
            ).is_file()
        )
        self.assertTrue(all(len(item["sha256"]) == 64 for item in resolved["members"]))

    def test_missing_platform_report_is_rejected(self) -> None:
        (self.reports / "reports-windows_amd64/public-suite.json").unlink()
        with self.assertRaisesRegex(bundle.Bundle_Error, "windows_amd64"):
            self.assemble()

    def test_nonzero_unresolved_counter_is_rejected(self) -> None:
        path = self.reports / "reports-linux_amd64/sanitizer-fuzz.json"
        report = json.loads(path.read_text())
        report["sanitizer_findings"] = 1
        path.write_text(json.dumps(report))
        with self.assertRaisesRegex(bundle.Bundle_Error, "sanitizer_findings"):
            self.assemble()

    def test_short_sanitizer_campaign_is_rejected(self) -> None:
        path = self.reports / "reports-darwin_arm64/sanitizer-fuzz.json"
        report = json.loads(path.read_text())
        report["aggregate_duration_seconds"] = 299
        path.write_text(json.dumps(report))
        with self.assertRaisesRegex(bundle.Bundle_Error, "300"):
            self.assemble()

    def test_cross_target_platform_label_is_rejected(self) -> None:
        path = self.reports / "reports-linux_amd64/public-suite.json"
        report = json.loads(path.read_text())
        report["platform"] = "darwin_arm64"
        path.write_text(json.dumps(report))
        with self.assertRaisesRegex(bundle.Bundle_Error, "platform"):
            self.assemble()

    def test_stale_source_revision_is_rejected(self) -> None:
        path = self.reports / "reports-linux_arm64/public-suite.json"
        report = json.loads(path.read_text())
        report["source_revision"] = "stale"
        path.write_text(json.dumps(report))
        with self.assertRaisesRegex(bundle.Bundle_Error, "source revision"):
            self.assemble()

    def test_altered_preserved_log_is_rejected(self) -> None:
        path = self.reports / "reports-darwin_amd64/sanitizer-fuzz.log"
        path.write_text("altered after report generation\n")
        with self.assertRaisesRegex(bundle.Bundle_Error, "SHA-256|log bytes"):
            self.assemble()

    def test_performance_threshold_fields_are_rejected(self) -> None:
        report = json.loads(
            (ROOT / "benchmarks/baselines/performance-darwin-arm64.json").read_text()
        )
        report["results"][0]["threshold_ns"] = 1
        with self.assertRaisesRegex(bundle.Bundle_Error, "threshold"):
            bundle.validate_performance_baseline(report)

    def test_missing_benchmark_category_is_rejected(self) -> None:
        report = json.loads(
            (ROOT / "benchmarks/baselines/performance-darwin-arm64.json").read_text()
        )
        report["results"] = copy.deepcopy(report["results"][:-1])
        with self.assertRaisesRegex(bundle.Bundle_Error, "codec-heavy"):
            bundle.validate_performance_baseline(report)


if __name__ == "__main__":
    unittest.main()

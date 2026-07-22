#!/usr/bin/env python3
"""Verify the maintained public diagnostic acceptance ledger is exhaustive."""

from __future__ import annotations

import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DECLARATION_SOURCES = (
    (ROOT / "errors.odin", "", None),
    (ROOT / "codecs.odin", "", None),
    (ROOT / "external" / "temporal" / "types.odin", "temporal.", {"Error"}),
)
LEDGER = ROOT / "tests" / "diagnostic_acceptance" / "diagnostic-ledger.json"

ENUM_RE = re.compile(r"^(\w+)\s*::\s*enum(?:\s+\w+)?\s*\{(.*?)^\}", re.MULTILINE | re.DOTALL)
UNION_RE = re.compile(r"^(\w+)\s*::\s*union(?:\s+#\w+)?\s*\{(.*?)^\}", re.MULTILINE | re.DOTALL)
MEMBER_RE = re.compile(r"^\s*([A-Za-z_][A-Za-z0-9_.]*)\s*,?\s*(?://.*)?$", re.MULTILINE)


def declarations() -> dict[str, list[str]]:
    result: dict[str, list[str]] = {}
    for path, prefix, selected in DECLARATION_SOURCES:
        source = path.read_text()
        for name, body in ENUM_RE.findall(source):
            if selected is None or name in selected:
                result[prefix + name] = MEMBER_RE.findall(body)
        for name, body in UNION_RE.findall(source):
            if selected is None and (name.endswith("_Error") or name.endswith("_Detail")):
                result[prefix + name] = MEMBER_RE.findall(body)
    return result


def names_public_test(source: str, procedure: str) -> bool:
    return re.search(
        rf"@\(test\)\s*{re.escape(procedure)}\s*::\s*proc\b", source
    ) is not None


def validate_test_references(
    references: list[str], owner: str, failures: list[str]
) -> None:
    for reference in references:
        if "::" not in reference:
            failures.append(f"{owner}: invalid test reference {reference!r}")
            continue
        relative, procedure = reference.split("::", 1)
        path = ROOT / relative
        if not path.is_file():
            failures.append(f"{owner}: missing test file {relative}")
        elif not names_public_test(path.read_text(), procedure):
            failures.append(f"{owner}: missing @(test) procedure {reference}")


def main() -> int:
    expected = {
        f"{declaration}.{member}"
        for declaration, members in declarations().items()
        for member in members
    }
    data = json.loads(LEDGER.read_text())
    entries = data.get("entries", [])
    actual = {entry.get("id") for entry in entries}
    failures: list[str] = []
    missing = sorted(expected - actual)
    extra = sorted(actual - expected)
    if missing:
        failures.append("missing declaration rows: " + ", ".join(missing))
    if extra:
        failures.append("unknown declaration rows: " + ", ".join(extra))
    if len(actual) != len(entries):
        failures.append("duplicate declaration row ids")

    for entry in entries:
        row_id = entry.get("id", "<missing>")
        status = entry.get("status")
        tests = entry.get("tests", [])
        justification = entry.get("justification", "").strip()
        if status == "covered":
            if not tests:
                failures.append(f"{row_id}: covered row has no public test")
        elif status == "inapplicable":
            if tests:
                failures.append(f"{row_id}: inapplicable row must not claim a test")
            if not justification:
                failures.append(f"{row_id}: inapplicable row has no justification")
        else:
            failures.append(f"{row_id}: invalid status {status!r}")
        validate_test_references(tests, row_id, failures)

    contracts = data.get("contracts", [])
    contract_ids = {entry.get("id") for entry in contracts}
    if len(contract_ids) != len(contracts):
        failures.append("duplicate contract row ids")
    required_contracts = {
        "coordinates-and-ranges",
        "payload-fields",
        "source-value-kinds",
        "definition-pairs-and-related-ranges",
        "parse-input-lifetime",
        "parse-key-truncation",
        "path-truncation",
        "encode-path-borrow-lifetime",
        "configuration-precedence",
        "source-traversal-precedence",
        "allocator-errors",
        "writer-errors",
        "codec-errors",
        "external-error-values",
        "nil-success",
        "options",
        "required-results",
        "wrapped-temporal-errors",
    }
    missing_contracts = sorted(required_contracts - contract_ids)
    if missing_contracts:
        failures.append("missing contract rows: " + ", ".join(missing_contracts))
    for contract in contracts:
        if not contract.get("tests") and not contract.get("evidence"):
            failures.append(f"contract {contract.get('id')}: no test or evidence")
        validate_test_references(
            contract.get("tests", []), f"contract {contract.get('id')}", failures
        )

    if failures:
        print("diagnostic ledger check failed:")
        for failure in failures:
            print(f"- {failure}")
        return 1
    covered = sum(entry["status"] == "covered" for entry in entries)
    inapplicable = len(entries) - covered
    print(
        f"diagnostic ledger covers {covered} declaration members and justifies "
        f"{inapplicable} inapplicable members; {len(contracts)} cross-cutting contracts mapped"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

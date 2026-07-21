#!/usr/bin/env python3
"""Resumable, single-writer automation for the TOML implementation tickets."""

from __future__ import annotations

import argparse
import contextlib
import dataclasses
import hashlib
import json
import os
import re
import secrets
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from string import Template
from typing import Any, Iterable, Iterator, Mapping, Sequence


DEFAULT_ISSUES = Path(".scratch/toml-package-implementation/issues")
DEFAULT_PROMPT = Path("scripts/toml_ticket_prompt.txt")
STATUS_READY = "ready-for-agent"
STATUS_COMPLETE = "resolved"
STATE_VERSION = 1
RECEIPT_VERSION = 1

EXIT_CONFIGURATION = 2
EXIT_BLOCKED = 3
EXIT_PI_FAILURE = 4
EXIT_INVARIANT = 5

TITLE_RE = re.compile(r"^# (?P<id>\d{2}) — (?P<title>.+)$", re.MULTILINE)
STATUS_RE = re.compile(r"^\*\*Status:\*\* (?P<status>[^\n]+)$", re.MULTILINE)
BLOCKERS_RE = re.compile(r"^\*\*Blocked by:\*\* (?P<blockers>[^\n]+)$", re.MULTILINE)
CHECKBOX_RE = re.compile(r"^- \[(?P<mark>[ xX])\] (?P<text>.+)$", re.MULTILINE)
BLOCKER_REF_RE = re.compile(r"(?P<id>\d{2}) — (?P<title>[^;.]+)")


class RunnerError(RuntimeError):
    exit_code = EXIT_CONFIGURATION


class BlockedError(RunnerError):
    exit_code = EXIT_BLOCKED


class PiExecutionError(RunnerError):
    exit_code = EXIT_PI_FAILURE


class InvariantError(RunnerError):
    exit_code = EXIT_INVARIANT


@dataclasses.dataclass(frozen=True)
class Criterion:
    text: str
    checked: bool


@dataclasses.dataclass(frozen=True)
class Ticket:
    id: int
    title: str
    path: Path
    status: str
    blockers: tuple[int, ...]
    blocker_titles: tuple[str, ...]
    criteria: tuple[Criterion, ...]
    raw_text: str

    @property
    def is_complete(self) -> bool:
        return self.status == STATUS_COMPLETE and all(c.checked for c in self.criteria)

    @property
    def immutable_contract(self) -> str:
        text = STATUS_RE.sub("**Status:** <status>", self.raw_text)
        return CHECKBOX_RE.sub(lambda m: f"- [ ] {m.group('text')}", text)


@dataclasses.dataclass(frozen=True)
class PiRunResult:
    final_text: str
    saw_agent_end: bool
    malformed_event_lines: int


def parse_ticket_text(path: Path, text: str) -> Ticket:
    title_matches = list(TITLE_RE.finditer(text))
    status_matches = list(STATUS_RE.finditer(text))
    blocker_matches = list(BLOCKERS_RE.finditer(text))
    if len(title_matches) != 1:
        raise RunnerError(f"{path}: expected exactly one numbered H1")
    if len(status_matches) != 1:
        raise RunnerError(f"{path}: expected exactly one status line")
    if len(blocker_matches) != 1:
        raise RunnerError(f"{path}: expected exactly one blocker line")

    match = title_matches[0]
    ticket_id = int(match.group("id"))
    if re.match(r"^\d{2}-", path.name) and int(path.name[:2]) != ticket_id:
        raise RunnerError(f"{path}: filename and heading ticket numbers differ")

    status = status_matches[0].group("status").strip()
    if status not in {STATUS_READY, STATUS_COMPLETE}:
        raise RunnerError(f"{path}: unsupported status {status!r}")

    criteria = tuple(
        Criterion(text=m.group("text").strip(), checked=m.group("mark").lower() == "x")
        for m in CHECKBOX_RE.finditer(text)
    )
    if not criteria:
        raise RunnerError(f"{path}: ticket has no acceptance criteria")
    checked_count = sum(c.checked for c in criteria)
    if status == STATUS_COMPLETE and checked_count != len(criteria):
        raise RunnerError(f"{path}: resolved ticket has unchecked acceptance criteria")
    if status == STATUS_READY and checked_count:
        raise RunnerError(f"{path}: ready ticket has partially checked acceptance criteria")

    blocker_text = blocker_matches[0].group("blockers").strip()
    refs = list(BLOCKER_REF_RE.finditer(blocker_text))
    if blocker_text.startswith("None"):
        if refs:
            raise RunnerError(f"{path}: blocker line mixes None with ticket references")
        blockers: tuple[int, ...] = ()
        blocker_titles: tuple[str, ...] = ()
    else:
        if not refs:
            raise RunnerError(f"{path}: malformed blocker line")
        blockers = tuple(int(m.group("id")) for m in refs)
        blocker_titles = tuple(m.group("title").strip() for m in refs)
        if len(set(blockers)) != len(blockers):
            raise RunnerError(f"{path}: duplicate blocker reference")

    return Ticket(
        id=ticket_id,
        title=match.group("title").strip(),
        path=path,
        status=status,
        blockers=blockers,
        blocker_titles=blocker_titles,
        criteria=criteria,
        raw_text=text,
    )


def discover_tickets(issue_dir: Path) -> dict[int, Ticket]:
    if not issue_dir.is_dir():
        raise RunnerError(f"Ticket directory does not exist: {issue_dir}")
    tickets: dict[int, Ticket] = {}
    for path in sorted(issue_dir.glob("[0-9][0-9]-*.md")):
        ticket = parse_ticket_text(path, path.read_text(encoding="utf-8"))
        if ticket.id in tickets:
            raise RunnerError(f"Duplicate ticket number {ticket.id:02d}")
        tickets[ticket.id] = ticket
    return dict(sorted(tickets.items()))


def validate_graph(tickets: Mapping[int, Ticket], expected_count: int | None = None) -> None:
    if not tickets:
        raise RunnerError("No implementation tickets found")
    ids = sorted(tickets)
    expected = list(range(1, (expected_count or len(ids)) + 1))
    if ids != expected:
        raise RunnerError(f"Ticket numbers must be contiguous: expected {expected}, found {ids}")
    for ticket in tickets.values():
        for blocker, blocker_title in zip(ticket.blockers, ticket.blocker_titles):
            if blocker not in tickets:
                raise RunnerError(f"Ticket {ticket.id:02d} references unknown blocker {blocker:02d}")
            if blocker >= ticket.id:
                raise RunnerError(
                    f"Ticket {ticket.id:02d} blocker {blocker:02d} must be an earlier ticket"
                )
            if tickets[blocker].title != blocker_title:
                raise RunnerError(
                    f"Ticket {ticket.id:02d} blocker {blocker:02d} title does not match"
                )


def select_next_ticket(
    tickets: Mapping[int, Ticket],
    completed_override: set[int] | None = None,
    excluded: set[int] | None = None,
) -> Ticket | None:
    complete = (
        {ticket.id for ticket in tickets.values() if ticket.is_complete}
        if completed_override is None
        else set(completed_override)
    )
    excluded = excluded or set()
    unfinished = [ticket for ticket in tickets.values() if ticket.id not in complete]
    if not unfinished:
        return None
    for ticket in unfinished:
        if ticket.id not in excluded and set(ticket.blockers) <= complete:
            return ticket
    details = ", ".join(
        f"{ticket.id:02d} waits for {sorted(set(ticket.blockers) - complete)}"
        for ticket in unfinished
        if ticket.id not in excluded
    )
    raise RunnerError(f"No runnable ticket; unresolved edges: {details or 'all frontier tickets excluded'}")


def manifest_hash(tickets: Mapping[int, Ticket]) -> str:
    payload = [
        {
            "id": ticket.id,
            "title": ticket.title,
            "blockers": list(ticket.blockers),
            "criteria": [c.text for c in ticket.criteria],
            "contract": ticket.immutable_contract,
        }
        for ticket in tickets.values()
    ]
    encoded = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(encoded).hexdigest()


def build_prompt(
    prompt_path: Path,
    *,
    ticket: Ticket,
    base_commit: str,
    receipt_path: Path,
    nonce: str,
    repo_root: Path,
) -> str:
    if not prompt_path.is_file():
        raise RunnerError(f"Prompt template does not exist: {prompt_path}")
    template = Template(prompt_path.read_text(encoding="utf-8"))
    body = template.substitute(
        ticket_id=f"{ticket.id:02d}",
        ticket_title=ticket.title,
        ticket_path=str(ticket.path.resolve()),
        nonce=nonce,
        repo_root=str(repo_root.resolve()),
        base_commit=base_commit,
        receipt_path=str(receipt_path.resolve()),
        implementation_spec=str((repo_root / ".scratch/toml-package-implementation/spec.md").resolve()),
        design_spec=str((repo_root / ".scratch/toml-package-design/spec.md").resolve()),
        interface_freeze=str(
            (repo_root / ".scratch/toml-package-design/public-interface-freeze.md").resolve()
        ),
    )
    return "/skill:implement " + body


def require_nonempty_list(data: Mapping[str, Any], field: str) -> list[Any]:
    value = data.get(field)
    if not isinstance(value, list) or not value:
        raise RunnerError(f"Receipt field {field!r} must be a non-empty array")
    return value


def validate_test_records(data: Mapping[str, Any], field: str) -> None:
    records = require_nonempty_list(data, field)
    for record in records:
        if not isinstance(record, dict) or not str(record.get("command", "")).strip():
            raise RunnerError(f"Receipt {field!r} contains a test without a command")
        if record.get("result") != "passed":
            raise RunnerError(f"Receipt {field!r} contains a non-passing test")


def validate_receipt(
    data: Mapping[str, Any],
    *,
    ticket_id: int,
    nonce: str,
    base_commit: str,
    final_commit: str,
) -> None:
    exact = {
        "version": RECEIPT_VERSION,
        "ticket": f"{ticket_id:02d}",
        "nonce": nonce,
        "base_commit": base_commit,
        "final_commit": final_commit,
        "result": "complete",
    }
    for field, expected in exact.items():
        if data.get(field) != expected:
            raise RunnerError(f"Receipt field {field!r} does not match the run")
    require_nonempty_list(data, "plan")
    cycles = require_nonempty_list(data, "tdd_cycles")
    for cycle in cycles:
        if not isinstance(cycle, dict) or any(
            not str(cycle.get(field, "")).strip() for field in ("test", "red", "green")
        ):
            raise RunnerError("Receipt contains an incomplete TDD cycle")
    for field in ("focused_tests", "full_tests", "final_tests"):
        validate_test_records(data, field)
    precommit = data.get("precommit_review")
    if not isinstance(precommit, dict) or precommit.get("status") != "passed":
        raise RunnerError("Receipt precommit review did not pass")
    if not isinstance(precommit.get("findings"), list) or not isinstance(precommit.get("fixes"), list):
        raise RunnerError("Receipt precommit review findings/fixes must be arrays")
    code_review = data.get("code_review")
    if not isinstance(code_review, dict):
        raise RunnerError("Receipt code_review must be an object")
    for axis in ("standards", "spec"):
        result = code_review.get(axis)
        if not isinstance(result, dict) or result.get("status") != "passed":
            raise RunnerError(f"Receipt code-review {axis} axis did not pass")
        if not isinstance(result.get("findings"), list):
            raise RunnerError(f"Receipt code-review {axis} findings must be an array")
    if data.get("unresolved_blockers") != []:
        raise RunnerError("Receipt contains unresolved blockers")


def extract_text(content: Any) -> str:
    if isinstance(content, str):
        return content
    if not isinstance(content, list):
        return ""
    return "".join(
        item.get("text", "") for item in content if isinstance(item, dict) and item.get("type") == "text"
    )


def validate_skill_expansion(session_dir: Path, nonce: str) -> Path:
    sessions = sorted(session_dir.rglob("*.jsonl"))
    if len(sessions) != 1:
        raise RunnerError(f"Expected exactly one fresh Pi session, found {len(sessions)}")
    first_user = ""
    with sessions[0].open(encoding="utf-8") as handle:
        for line in handle:
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue
            message = event.get("message") if isinstance(event, dict) else None
            if isinstance(message, dict) and message.get("role") == "user":
                first_user = extract_text(message.get("content"))
                break
    if '<skill name="implement"' not in first_user or nonce not in first_user:
        raise RunnerError("Pi did not expand /skill:implement in the fresh session")
    if "/skill:implement" in first_user:
        raise RunnerError("Pi session retained an unexpanded /skill:implement command")
    return sessions[0]


def git(repo_root: Path, *args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        ["git", *args], cwd=repo_root, text=True, capture_output=True, check=False
    )
    if check and result.returncode:
        message = result.stderr.strip() or result.stdout.strip()
        raise RunnerError(f"git {' '.join(args)} failed: {message}")
    return result


def git_stdout(repo_root: Path, *args: str) -> str:
    return git(repo_root, *args).stdout.strip()


def require_clean_repository(repo_root: Path) -> None:
    status = git_stdout(repo_root, "status", "--porcelain=v1", "--untracked-files=all")
    if status:
        raise InvariantError(f"Repository must be completely clean:\n{status}")
    git_dir = Path(git_stdout(repo_root, "rev-parse", "--absolute-git-dir"))
    operation_paths = (
        "MERGE_HEAD",
        "CHERRY_PICK_HEAD",
        "REVERT_HEAD",
        "BISECT_LOG",
        "rebase-merge",
        "rebase-apply",
        "sequencer",
    )
    active = [name for name in operation_paths if (git_dir / name).exists()]
    if active:
        raise InvariantError(f"Git operation in progress: {', '.join(active)}")


def ticket_relpath(repo_root: Path, ticket: Ticket) -> str:
    try:
        return str(ticket.path.resolve().relative_to(repo_root.resolve()))
    except ValueError as exc:
        raise RunnerError(f"Ticket is outside repository: {ticket.path}") from exc


def validate_post_ticket_git(
    *,
    repo_root: Path,
    base_commit: str,
    ticket: Ticket,
    tickets_before: Mapping[int, Ticket],
    tickets_after: Mapping[int, Ticket],
) -> str:
    require_clean_repository(repo_root)
    final = git_stdout(repo_root, "rev-parse", "HEAD")
    count = int(git_stdout(repo_root, "rev-list", "--count", f"{base_commit}..{final}"))
    if count != 1:
        raise InvariantError(f"Ticket must produce exactly one commit; found {count}")
    parents = git_stdout(repo_root, "rev-list", "--parents", "-n", "1", final).split()
    if len(parents) != 2 or parents[1] != base_commit:
        raise InvariantError("Ticket commit must be a non-merge child of the captured base")
    subject = git_stdout(repo_root, "show", "-s", "--format=%s", final)
    expected_subject = f"ticket {ticket.id:02d}: {ticket.title}"
    if subject != expected_subject:
        raise InvariantError(f"Ticket commit subject must be exactly {expected_subject!r}")
    if set(tickets_before) != set(tickets_after):
        raise InvariantError("Ticket files were added or removed")
    before_active = tickets_before[ticket.id]
    after_active = tickets_after[ticket.id]
    if before_active.status != STATUS_READY or any(c.checked for c in before_active.criteria):
        raise InvariantError("Active ticket did not begin in ready, unchecked state")
    if not after_active.is_complete:
        raise InvariantError("Active ticket is not resolved with every criterion checked")
    if before_active.immutable_contract != after_active.immutable_contract:
        raise InvariantError("Active ticket contract changed beyond status and checkbox markers")
    for ticket_id in tickets_before:
        if ticket_id != ticket.id and tickets_before[ticket_id].raw_text != tickets_after[ticket_id].raw_text:
            raise InvariantError(f"Ticket {ticket_id:02d} changed while implementing {ticket.id:02d}")
    changed = set(git_stdout(repo_root, "diff", "--name-only", base_commit, final).splitlines())
    if ticket_relpath(repo_root, after_active) not in changed:
        raise InvariantError("Ticket commit did not include its resolved ticket file")
    return final


def resolve_skill(repo_root: Path, name: str) -> Path:
    candidates = (
        repo_root / ".agents" / "skills" / name / "SKILL.md",
        repo_root / ".pi" / "skills" / name / "SKILL.md",
        Path.home() / ".agents" / "skills" / name / "SKILL.md",
        Path.home() / ".pi" / "agent" / "skills" / name / "SKILL.md",
    )
    for candidate in candidates:
        if candidate.is_file():
            return candidate.resolve()
    raise RunnerError(f"Required skill is not installed: {name}")


def tool_version(command: Sequence[str], cwd: Path) -> str:
    result = subprocess.run(command, cwd=cwd, text=True, capture_output=True, check=False)
    return (result.stdout or result.stderr).strip()


def run_pi(
    *,
    repo_root: Path,
    pi_bin: str,
    prompt: str,
    ticket: Ticket,
    attempt_dir: Path,
    model: str | None,
    thinking: str,
    skill_paths: Sequence[Path],
) -> PiRunResult:
    session_dir = attempt_dir / "session"
    session_dir.mkdir(parents=True, exist_ok=False)
    events_path = attempt_dir / "events.jsonl"
    stderr_path = attempt_dir / "stderr.log"
    command = [
        pi_bin,
        "--mode",
        "json",
        "--approve",
        "--session-dir",
        str(session_dir),
        "--name",
        f"toml-ticket-{ticket.id:02d}",
        "--thinking",
        thinking,
    ]
    if model:
        command += ["--model", model]
    for skill_path in skill_paths:
        command += ["--skill", str(skill_path)]
    command.append(prompt)
    (attempt_dir / "command.json").write_text(json.dumps(command, indent=2) + "\n", encoding="utf-8")

    final_text = ""
    saw_agent_end = False
    malformed = 0
    with events_path.open("w", encoding="utf-8") as events, stderr_path.open(
        "w", encoding="utf-8"
    ) as stderr:
        process = subprocess.Popen(
            command,
            cwd=repo_root,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=stderr,
            text=True,
            bufsize=1,
        )
        try:
            assert process.stdout is not None
            for line in process.stdout:
                events.write(line)
                events.flush()
                try:
                    event = json.loads(line)
                except json.JSONDecodeError:
                    malformed += 1
                    continue
                if event.get("type") == "agent_end":
                    saw_agent_end = True
                if event.get("type") == "message_end":
                    message = event.get("message")
                    if isinstance(message, dict) and message.get("role") == "assistant":
                        final_text = extract_text(message.get("content"))
        except KeyboardInterrupt:
            process.send_signal(signal.SIGINT)
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.terminate()
            raise PiExecutionError("Pi ticket run interrupted")
        return_code = process.wait()
    if return_code:
        raise PiExecutionError(
            f"Pi exited with status {return_code}; see {stderr_path} and {events_path}"
        )
    if malformed:
        raise PiExecutionError(f"Pi emitted {malformed} malformed JSON event lines")
    if not saw_agent_end:
        raise PiExecutionError("Pi event stream ended without agent_end")
    marker = final_text.rstrip().splitlines()[-1] if final_text.strip() else ""
    if marker == "TICKET_RESULT: BLOCKED":
        raise BlockedError(f"Ticket {ticket.id:02d} reported BLOCKED; see {events_path}")
    if marker != "TICKET_RESULT: COMPLETE":
        raise PiExecutionError("Pi final response did not end with TICKET_RESULT: COMPLETE")
    return PiRunResult(final_text=final_text, saw_agent_end=saw_agent_end, malformed_event_lines=malformed)


def read_json(path: Path) -> dict[str, Any]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise RunnerError(f"Required JSON file is missing: {path}") from exc
    except json.JSONDecodeError as exc:
        raise RunnerError(f"Invalid JSON in {path}: {exc}") from exc
    if not isinstance(data, dict):
        raise RunnerError(f"Expected a JSON object in {path}")
    return data


def atomic_write_json(path: Path, data: Mapping[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temp_name = tempfile.mkstemp(prefix=path.name + ".", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(data, handle, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temp_name, path)
    finally:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(temp_name)


@contextlib.contextmanager
def runner_lock(lock_path: Path) -> Iterator[None]:
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    handle = lock_path.open("a+b")
    try:
        if os.name == "nt":
            import msvcrt

            try:
                msvcrt.locking(handle.fileno(), msvcrt.LK_NBLCK, 1)
            except OSError as exc:
                raise RunnerError("Another ticket runner is active") from exc
        else:
            import fcntl

            try:
                fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError as exc:
                raise RunnerError("Another ticket runner is active") from exc
        yield
    finally:
        if os.name == "nt":
            import msvcrt

            with contextlib.suppress(OSError):
                handle.seek(0)
                msvcrt.locking(handle.fileno(), msvcrt.LK_UNLCK, 1)
        else:
            import fcntl

            with contextlib.suppress(OSError):
                fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
        handle.close()


def initial_state(tickets: Mapping[int, Ticket], head: str) -> dict[str, Any]:
    complete = [ticket.id for ticket in tickets.values() if ticket.is_complete]
    if complete:
        raise RunnerError(
            "Cannot create runner state over already-resolved tickets; audit/reconstruct state first"
        )
    return {
        "version": STATE_VERSION,
        "manifest": manifest_hash(tickets),
        "baseline": head,
        "completed": [],
        "attempts": {},
        "active": None,
    }


def validate_state(
    state: Mapping[str, Any], tickets: Mapping[int, Ticket], current_head: str
) -> None:
    if state.get("version") != STATE_VERSION:
        raise RunnerError("Unsupported runner state version")
    if state.get("manifest") != manifest_hash(tickets):
        raise RunnerError("Ticket manifest changed outside permitted status/checkbox transitions")
    completed = state.get("completed")
    if not isinstance(completed, list):
        raise RunnerError("Runner state completed ledger is invalid")
    ledger_ids = [entry.get("ticket") for entry in completed if isinstance(entry, dict)]
    actual_ids = [f"{ticket.id:02d}" for ticket in tickets.values() if ticket.is_complete]
    if ledger_ids != actual_ids:
        raise RunnerError(f"Resolved ticket files and runner ledger disagree: {actual_ids} != {ledger_ids}")
    expected_head = completed[-1].get("commit") if completed else state.get("baseline")
    if state.get("active") is None and current_head != expected_head:
        raise RunnerError("Git history drifted from the runner completion ledger")


def discover_tickets_at_commit(repo_root: Path, issue_dir: Path, commit: str) -> dict[int, Ticket]:
    rel_dir = issue_dir.resolve().relative_to(repo_root.resolve())
    names = git_stdout(repo_root, "ls-tree", "-r", "--name-only", commit, "--", str(rel_dir)).splitlines()
    tickets: dict[int, Ticket] = {}
    for name in sorted(names):
        path = Path(name)
        if not re.match(r"^\d{2}-.*\.md$", path.name):
            continue
        text = git_stdout(repo_root, "show", f"{commit}:{name}") + "\n"
        ticket = parse_ticket_text(repo_root / path, text)
        tickets[ticket.id] = ticket
    return dict(sorted(tickets.items()))


def finalize_attempt(
    *,
    repo_root: Path,
    issue_dir: Path,
    state: dict[str, Any],
    active: Mapping[str, Any],
) -> None:
    ticket_id = int(active["ticket"])
    base = str(active["base_commit"])
    nonce = str(active["nonce"])
    attempt_dir = Path(str(active["attempt_dir"]))
    receipt_path = Path(str(active["receipt_path"]))
    before = discover_tickets_at_commit(repo_root, issue_dir, base)
    after = discover_tickets(issue_dir)
    validate_graph(after)
    final = validate_post_ticket_git(
        repo_root=repo_root,
        base_commit=base,
        ticket=after[ticket_id],
        tickets_before=before,
        tickets_after=after,
    )
    validate_skill_expansion(attempt_dir / "session", nonce)
    receipt = read_json(receipt_path)
    validate_receipt(
        receipt,
        ticket_id=ticket_id,
        nonce=nonce,
        base_commit=base,
        final_commit=final,
    )
    state["completed"].append(
        {"ticket": f"{ticket_id:02d}", "base": base, "commit": final, "completed_at": int(time.time())}
    )
    state["active"] = None
    atomic_write_json(Path(active["state_path"]), state)
    atomic_write_json(
        attempt_dir / "result.json",
        {"status": "complete", "ticket": f"{ticket_id:02d}", "base": base, "commit": final},
    )


def recover_active(
    *, repo_root: Path, issue_dir: Path, state: dict[str, Any], state_path: Path
) -> None:
    active = state.get("active")
    if not isinstance(active, dict):
        return
    base = str(active.get("base_commit", ""))
    current = git_stdout(repo_root, "rev-parse", "HEAD")
    require_clean_repository(repo_root)
    if current == base:
        state["active"] = None
        atomic_write_json(state_path, state)
        return
    active["state_path"] = str(state_path)
    finalize_attempt(repo_root=repo_root, issue_dir=issue_dir, state=state, active=active)


def run_loop(args: argparse.Namespace) -> int:
    repo_root = Path(git_stdout(Path.cwd(), "rev-parse", "--show-toplevel")).resolve()
    issue_dir = (repo_root / args.issues).resolve() if not args.issues.is_absolute() else args.issues.resolve()
    prompt_path = (repo_root / args.prompt).resolve() if not args.prompt.is_absolute() else args.prompt.resolve()
    git(repo_root, "rev-parse", "--verify", "HEAD")
    require_clean_repository(repo_root)
    tickets = discover_tickets(issue_dir)
    validate_graph(tickets, expected_count=args.expected_count)

    skill_paths = [resolve_skill(repo_root, name) for name in ("implement", "tdd", "code-review")]
    if args.dry_run:
        virtual = {ticket.id for ticket in tickets.values() if ticket.is_complete}
        sequence: list[str] = []
        while len(virtual) < len(tickets):
            ticket = select_next_ticket(tickets, completed_override=virtual)
            assert ticket is not None
            sequence.append(f"{ticket.id:02d} — {ticket.title}")
            virtual.add(ticket.id)
        print(f"Baseline: {git_stdout(repo_root, 'rev-parse', 'HEAD')}")
        print("Fresh Pi command: pi --mode json --approve --session-dir <attempt>/session ... /skill:implement ...")
        print("Runnable sequence:")
        print("\n".join(f"  {item}" for item in sequence))
        return 0

    git_dir = Path(git_stdout(repo_root, "rev-parse", "--absolute-git-dir"))
    runner_dir = git_dir / "pi-ticket-runner"
    state_path = runner_dir / "state.json"
    with runner_lock(runner_dir / "runner.lock"):
        tickets = discover_tickets(issue_dir)
        current_head = git_stdout(repo_root, "rev-parse", "HEAD")
        if state_path.exists():
            state = read_json(state_path)
        else:
            state = initial_state(tickets, current_head)
            atomic_write_json(state_path, state)
        validate_state(state, tickets, current_head)
        recover_active(repo_root=repo_root, issue_dir=issue_dir, state=state, state_path=state_path)

        completed_this_run = 0
        while True:
            require_clean_repository(repo_root)
            tickets = discover_tickets(issue_dir)
            validate_graph(tickets, expected_count=args.expected_count)
            ticket = select_next_ticket(tickets)
            if ticket is None:
                print("All implementation tickets are resolved.")
                return 0
            if args.max_tickets is not None and completed_this_run >= args.max_tickets:
                print(f"Reached --max-tickets={args.max_tickets}; next ticket is {ticket.id:02d}.")
                return 0

            base = git_stdout(repo_root, "rev-parse", "HEAD")
            attempt_number = int(state["attempts"].get(f"{ticket.id:02d}", 0)) + 1
            state["attempts"][f"{ticket.id:02d}"] = attempt_number
            nonce = secrets.token_hex(16)
            attempt_dir = runner_dir / "attempts" / f"{ticket.id:02d}-{attempt_number:03d}"
            attempt_dir.mkdir(parents=True, exist_ok=False)
            receipt_path = attempt_dir / "receipt.json"
            prompt = build_prompt(
                prompt_path,
                ticket=ticket,
                base_commit=base,
                receipt_path=receipt_path,
                nonce=nonce,
                repo_root=repo_root,
            )
            (attempt_dir / "prompt.txt").write_text(prompt, encoding="utf-8")
            metadata = {
                "ticket": f"{ticket.id:02d}",
                "title": ticket.title,
                "attempt": attempt_number,
                "nonce": nonce,
                "base_commit": base,
                "model": args.model,
                "thinking": args.thinking,
                "git_version": tool_version(["git", "--version"], repo_root),
                "pi_version": tool_version([args.pi_bin, "--version"], repo_root),
                "python_version": sys.version,
                "started_at": int(time.time()),
            }
            atomic_write_json(attempt_dir / "metadata.json", metadata)
            state["active"] = {
                "ticket": f"{ticket.id:02d}",
                "base_commit": base,
                "nonce": nonce,
                "attempt_dir": str(attempt_dir),
                "receipt_path": str(receipt_path),
            }
            atomic_write_json(state_path, state)
            print(f"\n=== Ticket {ticket.id:02d}: {ticket.title} (attempt {attempt_number}) ===")
            run_pi(
                repo_root=repo_root,
                pi_bin=args.pi_bin,
                prompt=prompt,
                ticket=ticket,
                attempt_dir=attempt_dir,
                model=args.model,
                thinking=args.thinking,
                skill_paths=skill_paths,
            )
            active = dict(state["active"])
            active["state_path"] = str(state_path)
            finalize_attempt(
                repo_root=repo_root,
                issue_dir=issue_dir,
                state=state,
                active=active,
            )
            completed_this_run += 1
            print(f"Completed and committed ticket {ticket.id:02d}.")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Run dependency-ready TOML implementation tickets in fresh Pi sessions. "
            "Completion is status 'resolved' plus every acceptance box checked."
        )
    )
    parser.add_argument("issues", nargs="?", type=Path, default=DEFAULT_ISSUES)
    parser.add_argument("--prompt", type=Path, default=DEFAULT_PROMPT)
    parser.add_argument("--pi-bin", default="pi")
    parser.add_argument("--model")
    parser.add_argument(
        "--thinking",
        choices=("off", "minimal", "low", "medium", "high", "xhigh", "max"),
        default="high",
    )
    parser.add_argument("--max-tickets", type=int)
    parser.add_argument("--expected-count", type=int, default=28)
    parser.add_argument("--dry-run", action="store_true")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if args.max_tickets is not None and args.max_tickets <= 0:
        parser.error("--max-tickets must be positive")
    try:
        return run_loop(args)
    except RunnerError as exc:
        print(f"ticket runner stopped: {exc}", file=sys.stderr)
        return exc.exit_code
    except FileNotFoundError as exc:
        print(f"ticket runner stopped: executable not found: {exc.filename}", file=sys.stderr)
        return EXIT_CONFIGURATION


if __name__ == "__main__":
    raise SystemExit(main())

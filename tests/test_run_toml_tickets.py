from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

from scripts import run_toml_tickets as runner


REPO_ROOT = Path(__file__).resolve().parents[1]
ISSUES = REPO_ROOT / ".scratch" / "toml-package-implementation" / "issues"
PROMPT = REPO_ROOT / "scripts" / "toml_ticket_prompt.txt"


class TicketParsingTests(unittest.TestCase):
    def test_real_ticket_graph_is_valid_and_starts_with_ticket_one(self) -> None:
        tickets = runner.discover_tickets(ISSUES)
        runner.validate_graph(tickets, expected_count=28)

        self.assertEqual(list(tickets), list(range(1, 29)))
        self.assertEqual(tickets[1].blockers, ())
        self.assertEqual(tickets[24].blockers, (10, 21, 23))
        self.assertEqual(runner.select_next_ticket(tickets), tickets[1])

    def test_resolved_requires_every_checkbox_checked(self) -> None:
        text = (ISSUES / "01-reproducible-scaffold-and-frozen-declarations.md").read_text()
        resolved = text.replace("**Status:** ready-for-agent", "**Status:** resolved").replace("- [ ]", "- [x]")
        ticket = runner.parse_ticket_text(Path("01-example.md"), resolved)
        self.assertTrue(ticket.is_complete)

        partial = resolved.replace("- [x]", "- [ ]", 1)
        with self.assertRaisesRegex(runner.RunnerError, "resolved.*unchecked"):
            runner.parse_ticket_text(Path("01-example.md"), partial)

    def test_graph_rejects_unknown_and_forward_blockers(self) -> None:
        one = runner.parse_ticket_text(
            Path("01-one.md"),
            "# 01 — One\n\n**What to build:** One.\n\n**Blocked by:** 02 — Two.\n\n"
            "**Status:** ready-for-agent\n\n- [ ] done\n",
        )
        two = runner.parse_ticket_text(
            Path("02-two.md"),
            "# 02 — Two\n\n**What to build:** Two.\n\n**Blocked by:** None — can start immediately.\n\n"
            "**Status:** ready-for-agent\n\n- [ ] done\n",
        )
        with self.assertRaisesRegex(runner.RunnerError, "earlier ticket"):
            runner.validate_graph({1: one, 2: two}, expected_count=2)

    def test_scheduler_reports_deadlock_when_no_frontier_exists(self) -> None:
        tickets = runner.discover_tickets(ISSUES)
        with self.assertRaisesRegex(runner.RunnerError, "No runnable ticket"):
            runner.select_next_ticket(tickets, completed_override=set(), excluded={1})


class PromptAndReceiptTests(unittest.TestCase):
    def test_prompt_forces_implement_skill_and_frozen_workflow(self) -> None:
        ticket = runner.discover_tickets(ISSUES)[1]
        prompt = runner.build_prompt(
            PROMPT,
            ticket=ticket,
            base_commit="a" * 40,
            receipt_path=Path("/tmp/receipt.json"),
            nonce="nonce-123",
            repo_root=REPO_ROOT,
        )

        self.assertTrue(prompt.startswith("/skill:implement "))
        self.assertIn("plan before editing", prompt.lower())
        self.assertIn("adversarial pre-commit review", prompt.lower())
        self.assertIn("code-review", prompt)
        self.assertIn("exactly one commit", prompt.lower())
        self.assertIn("nonce-123", prompt)
        self.assertIn("a" * 40, prompt)

    def test_receipt_requires_tdd_tests_and_both_review_axes(self) -> None:
        data = valid_receipt()
        runner.validate_receipt(
            data,
            ticket_id=1,
            nonce="nonce-123",
            base_commit="a" * 40,
            final_commit="b" * 40,
        )

        del data["code_review"]["spec"]
        with self.assertRaisesRegex(runner.RunnerError, "spec"):
            runner.validate_receipt(
                data,
                ticket_id=1,
                nonce="nonce-123",
                base_commit="a" * 40,
                final_commit="b" * 40,
            )

    def test_expanded_session_must_contain_implement_skill_and_nonce(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            session = Path(tmp) / "session.jsonl"
            session.write_text(
                json.dumps({"type": "session", "version": 3})
                + "\n"
                + json.dumps(
                    {
                        "type": "message",
                        "message": {
                            "role": "user",
                            "content": [
                                {
                                    "type": "text",
                                    "text": '<skill name="implement" location="/skill">body</skill>\nnonce-123',
                                }
                            ],
                        },
                    }
                )
                + "\n"
            )
            runner.validate_skill_expansion(Path(tmp), "nonce-123")

            session.write_text(
                json.dumps({"type": "session", "version": 3})
                + "\n"
                + json.dumps(
                    {
                        "type": "message",
                        "message": {
                            "role": "user",
                            "content": [{"type": "text", "text": "/skill:implement nonce-123"}],
                        },
                    }
                )
                + "\n"
            )
            with self.assertRaisesRegex(runner.RunnerError, "did not expand"):
                runner.validate_skill_expansion(Path(tmp), "nonce-123")


class GitInvariantTests(unittest.TestCase):
    def test_validate_single_ticket_commit_accepts_exact_transition(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            git(repo, "init")
            git(repo, "config", "user.email", "runner@example.com")
            git(repo, "config", "user.name", "Runner Test")
            issue_dir = repo / ".scratch" / "toml-package-implementation" / "issues"
            issue_dir.mkdir(parents=True)
            ticket_path = issue_dir / "01-one.md"
            ticket_path.write_text(
                "# 01 — One\n\n**What to build:** One.\n\n**Blocked by:** None — can start immediately.\n\n"
                "**Status:** ready-for-agent\n\n- [ ] criterion\n"
            )
            git(repo, "add", ".")
            git(repo, "commit", "-m", "baseline")
            base = git(repo, "rev-parse", "HEAD").strip()
            before = runner.discover_tickets(issue_dir)

            ticket_path.write_text(ticket_path.read_text().replace("ready-for-agent", "resolved").replace("[ ]", "[x]"))
            (repo / "implementation.txt").write_text("done\n")
            git(repo, "add", ".")
            git(repo, "commit", "-m", "ticket 01: One")
            after = runner.discover_tickets(issue_dir)

            runner.validate_post_ticket_git(
                repo_root=repo,
                base_commit=base,
                ticket=after[1],
                tickets_before=before,
                tickets_after=after,
            )

    def test_validate_single_ticket_commit_rejects_two_commits(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            git(repo, "init")
            git(repo, "config", "user.email", "runner@example.com")
            git(repo, "config", "user.name", "Runner Test")
            issue_dir = repo / ".scratch" / "toml-package-implementation" / "issues"
            issue_dir.mkdir(parents=True)
            ticket_path = issue_dir / "01-one.md"
            ticket_path.write_text(
                "# 01 — One\n\n**What to build:** One.\n\n**Blocked by:** None — can start immediately.\n\n"
                "**Status:** ready-for-agent\n\n- [ ] criterion\n"
            )
            git(repo, "add", ".")
            git(repo, "commit", "-m", "baseline")
            base = git(repo, "rev-parse", "HEAD").strip()
            before = runner.discover_tickets(issue_dir)
            (repo / "first.txt").write_text("first\n")
            git(repo, "add", ".")
            git(repo, "commit", "-m", "first")
            ticket_path.write_text(ticket_path.read_text().replace("ready-for-agent", "resolved").replace("[ ]", "[x]"))
            git(repo, "add", ".")
            git(repo, "commit", "-m", "ticket 01: One")
            after = runner.discover_tickets(issue_dir)

            with self.assertRaisesRegex(runner.RunnerError, "exactly one commit"):
                runner.validate_post_ticket_git(
                    repo_root=repo,
                    base_commit=base,
                    ticket=after[1],
                    tickets_before=before,
                    tickets_after=after,
                )


class CliIntegrationTests(unittest.TestCase):
    def test_one_ticket_run_uses_fresh_skill_session_and_commits_once(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            git(repo, "init")
            git(repo, "config", "user.email", "runner@example.com")
            git(repo, "config", "user.name", "Runner Test")
            issue_dir = repo / ".scratch" / "toml-package-implementation" / "issues"
            issue_dir.mkdir(parents=True)
            ticket_path = issue_dir / "01-one.md"
            ticket_path.write_text(
                "# 01 — One\\n\\n**What to build:** One.\\n\\n**Blocked by:** None — can start immediately.\\n\\n"
                "**Status:** ready-for-agent\\n\\n- [ ] criterion\\n"
            )
            (repo / ".scratch" / "toml-package-implementation" / "spec.md").write_text("spec\\n")
            design = repo / ".scratch" / "toml-package-design"
            design.mkdir(parents=True)
            (design / "spec.md").write_text("design\\n")
            (design / "public-interface-freeze.md").write_text("freeze\\n")
            git(repo, "add", ".")
            git(repo, "commit", "-m", "baseline")

            fake_pi = repo / ".git" / "fake-pi"
            fake_pi.write_text(fake_pi_source())
            fake_pi.chmod(0o755)
            result = subprocess.run(
                [
                    sys.executable,
                    str(REPO_ROOT / "scripts" / "run_toml_tickets.py"),
                    str(issue_dir),
                    "--prompt",
                    str(PROMPT),
                    "--expected-count",
                    "1",
                    "--max-tickets",
                    "1",
                    "--pi-bin",
                    str(fake_pi),
                ],
                cwd=repo,
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("Completed and committed ticket 01", result.stdout)
            self.assertIn("**Status:** resolved", ticket_path.read_text())
            self.assertNotIn("- [ ]", ticket_path.read_text())
            self.assertEqual(git(repo, "rev-list", "--count", "HEAD").strip(), "2")
            state = json.loads((repo / ".git" / "pi-ticket-runner" / "state.json").read_text())
            self.assertEqual(state["completed"][0]["ticket"], "01")
            self.assertIsNone(state["active"])


def fake_pi_source() -> str:
    return textwrap.dedent(
        r'''#!/usr/bin/env python3
import json
import re
import subprocess
import sys
from pathlib import Path

args = sys.argv[1:]
if "--version" in args:
    print("fake-pi 1.0")
    raise SystemExit(0)
prompt = args[-1]
assert prompt.startswith("/skill:implement ")
session_dir = Path(args[args.index("--session-dir") + 1])
session_dir.mkdir(parents=True, exist_ok=True)

def field(pattern):
    match = re.search(pattern, prompt)
    assert match, pattern
    return match.group(1).strip()

ticket_id = field(r"Implement ticket (\\d{2}) —")
title = field(r"Implement ticket \\d{2} — (.+) at:")
ticket_path = Path(field(r"at:\\n(.+)\\n\\nRun identity:"))
nonce = field(r"- nonce: (.+)")
base = field(r"- fixed review/base commit: ([0-9a-f]+)")
receipt_path = Path(field(r"- machine-readable receipt: (.+)"))
text = ticket_path.read_text().replace("**Status:** ready-for-agent", "**Status:** resolved").replace("- [ ]", "- [x]")
ticket_path.write_text(text)
Path("implementation.txt").write_text("done\\n")
subprocess.run(["git", "add", "."], check=True)
subprocess.run(["git", "commit", "-m", f"ticket {ticket_id}: {title}"], check=True, stdout=subprocess.DEVNULL)
final = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
receipt = {
    "version": 1,
    "ticket": ticket_id,
    "nonce": nonce,
    "base_commit": base,
    "final_commit": final,
    "result": "complete",
    "plan": ["plan"],
    "tdd_cycles": [{"test": "test", "red": "red", "green": "green"}],
    "focused_tests": [{"command": "focused", "result": "passed"}],
    "full_tests": [{"command": "full", "result": "passed"}],
    "precommit_review": {"status": "passed", "findings": [], "fixes": []},
    "code_review": {
        "standards": {"status": "passed", "findings": []},
        "spec": {"status": "passed", "findings": []},
    },
    "final_tests": [{"command": "final", "result": "passed"}],
    "unresolved_blockers": [],
}
receipt_path.write_text(json.dumps(receipt))
session = session_dir / "session.jsonl"
session.write_text(
    json.dumps({"type": "session", "version": 3}) + "\\n" +
    json.dumps({"type": "message", "message": {"role": "user", "content": [{"type": "text", "text": f'<skill name="implement" location="/skill">body</skill>\\n{nonce}'}]}}) + "\\n"
)
print(json.dumps({"type": "session", "version": 3}))
print(json.dumps({"type": "message_end", "message": {"role": "assistant", "content": [{"type": "text", "text": "done\\nTICKET_RESULT: COMPLETE"}]}}))
print(json.dumps({"type": "agent_end", "messages": []}))
'''
    )


def valid_receipt() -> dict:
    return {
        "version": 1,
        "ticket": "01",
        "nonce": "nonce-123",
        "base_commit": "a" * 40,
        "final_commit": "b" * 40,
        "result": "complete",
        "plan": ["implement the behavior"],
        "tdd_cycles": [{"test": "test command", "red": "failed as expected", "green": "passed"}],
        "focused_tests": [{"command": "focused", "result": "passed"}],
        "full_tests": [{"command": "full", "result": "passed"}],
        "precommit_review": {"status": "passed", "findings": [], "fixes": []},
        "code_review": {
            "standards": {"status": "passed", "findings": []},
            "spec": {"status": "passed", "findings": []},
        },
        "final_tests": [{"command": "full", "result": "passed"}],
        "unresolved_blockers": [],
    }


def git(repo: Path, *args: str) -> str:
    result = subprocess.run(["git", *args], cwd=repo, text=True, capture_output=True, check=True)
    return result.stdout


if __name__ == "__main__":
    unittest.main()

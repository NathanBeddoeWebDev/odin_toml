from __future__ import annotations

import json
import subprocess
import tempfile
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

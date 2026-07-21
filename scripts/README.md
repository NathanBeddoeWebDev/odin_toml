# TOML ticket runner

`run_toml_tickets.py` implements the dependency-ready tickets in `.scratch/toml-package-implementation/issues` one at a time. Each attempt uses a fresh non-interactive Pi session whose first prompt is the expanded `/skill:implement` skill.

## Prerequisites

- A clean repository with an existing baseline commit.
- `git`, `pi`, and Python 3.
- Authenticated Pi model access.
- Installed `implement`, `tdd`, and `code-review` skills.
- The subagent/review tooling required by `code-review`.
- Ticket-specific compilers, corpus tools, sanitizers, and platform infrastructure.

The runner treats an implementation ticket as complete only when its status is `resolved` and every acceptance checkbox is checked.

## Preview

```bash
python3 scripts/run_toml_tickets.py --dry-run
```

Dry-run validates the clean baseline and complete ticket graph, then prints the deterministic dependency-ready order without creating runner state or starting Pi.

## Run

```bash
python3 scripts/run_toml_tickets.py --model '<provider/model>'
```

Useful controls:

```bash
# Complete at most one ticket, then return successfully.
python3 scripts/run_toml_tickets.py --max-tickets 1

# Select a different reasoning level.
python3 scripts/run_toml_tickets.py --thinking xhigh
```

For every ticket, the child must plan first, work in red-green slices, test frequently, run an adversarial pre-commit review, fix findings, run the full applicable suite, create exactly one commit, run the implement skill's required Standards/Spec code review against the captured base, amend fixes into that commit, run final tests, resolve the ticket, and write a machine-readable receipt.

The runner independently verifies the receipt, expanded skill command, Git ancestry, exact one-commit rule, commit subject, ticket transition, unchanged neighboring tickets, and clean worktree before selecting another ticket.

## State and recovery

State, prompts, Pi sessions, JSON event logs, stderr, receipts, and results are retained under:

```text
.git/pi-ticket-runner/
```

Re-running the same command resumes from the first unresolved dependency-ready ticket. A clean interrupted attempt that never committed is retried in a new session. A committed interrupted attempt is finalized only when all normal receipt, session, ticket, and Git invariants pass.

The runner never resets, checks out, rebases, cleans, or pushes. It stops on dirty state, ambiguous history, failed evidence, a reported blocker, or an unavailable feasibility gate so a human can inspect the retained artifacts.

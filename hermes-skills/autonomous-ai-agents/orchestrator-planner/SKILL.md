---
name: orchestrator-planner
description: "Decompose a spec issue into contract-conforming tickets."
version: 0.2.0
author: local-ai-agent-explore
license: MIT
platforms: [linux, macos]
metadata:
  hermes:
    tags: [Planning, Decomposition, GitHub, Issues, Orchestration]
    related_skills: [github-issues, github-auth, plan]
---

# Orchestrator Planner

Turn one issue labelled `spec` into implementation issues that a dispatcher can
schedule and a worker can finish alone.

**You do not run the planning procedure. A script does.** `p3-plan.py plan` owns
the whole loop — it fetches the spec, asks a model for the file layout, asks for
one ticket at a time until every path in that layout is claimed, validates the
plan, creates the issues, links them under the spec and verifies the result. Your
job is to start it and report what it did.

This is version 0.2.0 because version 0.1.0 asked *you* to follow the seven steps,
and across four live runs that failed a different way every time: improvising
instead of starting, diagnosing a missing `jq` as a network outage, writing the
target project's code into the agent's own directory, stopping after one ticket —
and, worst, printing a confident five-ticket plan when the ledger held two. Where
the script owns control the output has never once been malformed. So the script
owns control.

## When to Use

- A target repository has an open issue labelled `spec` and no implementation
  issues yet.
- A previous planning run stopped part-way and must be resumed — run the *same*
  command again; it continues from the ledger.
- Don't use for: writing application code, approving tickets (`status:todo` is a
  human act), editing the target README.

## Prerequisites

Everything below is **already in your environment**. Do not ask the human for it.

- `TARGET_REPO` (`owner/name`) and `SPEC_ISSUE`.
- `GITHUB_TOKEN`, injected at runtime. Never print it, never write it to a file.
- `HTTPS_PROXY` pointing at the egress proxy — the agent has no direct route out.
- The contract's labels exist in the target repo (`bootstrap-labels.sh`).

## The whole procedure

Run this. That is the procedure.

```
terminal(command="P3=\"$HERMES_HOME/skills/autonomous-ai-agents/orchestrator-planner/scripts\"; python3 $P3/p3-plan.py plan --repo \"$TARGET_REPO\" --spec \"$SPEC_ISSUE\"")
```

It prints six numbered steps, then either a validated plan or a loud failure. It
is safe to run again: it resumes and never duplicates a ticket.

Then report to the human: the ticket count, the wave list the validator printed,
and that everything is `status:backlog` awaiting their approval.

### Do not, before or during this

- **Do not ask which repo or issue.** It is `$TARGET_REPO` / `$SPEC_ISSUE`. If one
  is genuinely empty the command fails and says which.
- **Do not clone the target repository.** The script fetches the issue and the
  README. A clone tells you nothing extra and costs turns.
- **Do not explore the filesystem** — no `git status`, no `grep`, no reading
  `pyproject.toml`. You are planning a project that does not exist yet.
- **Do not use `jq`** — it is not installed. `curl | jq` fails with exit 127,
  which looks like a network error and is not one.
- **Do not conclude the network is blocked.** Egress is proxied and works for
  `github.com` and `api.github.com`. Read the actual error first.
- **Do not write any application code. Not one file.** The paths in the tickets
  describe what a *worker* will create. If you catch yourself creating
  `__init__.py` or a test, stop.
- **Do not verify anything by running it.** There is no code yet. An acceptance
  command that fails today is correct — it is what a worker makes pass.
- **Do not write tickets yourself.** Not with `add`, not in prose, not in your
  final message. If the script stopped, say so and show its output.

## What the script does, so you can read its output

```
[1/6]  init the ledger; fetch the spec issue and the target README
[2/6]  ONE model call: the complete file layout
[3/6]  ONE model call per ticket, until every layout path is claimed
[4/6]  validate the whole plan (p3-plan-lint.py, a separate implementation)
[5/6]  create the issues, link each as a sub-issue of the spec, record the number
[6/6]  re-read what exists in GitHub and validate that
```

Every model call is one decision, constrained to a JSON object whose schema is in
the prompt, and validated on receipt. A malformed reply is retried with the parse
error fed back; when the retries run out the script **stops and prints the raw
reply**. It never invents a ticket to fill a gap.

### Exit codes

| Code | Meaning | What to do |
|---|---|---|
| 0 | the plan validates and the issues exist | report the waves to the human |
| 1 | usage, validation or GitHub error | read the message; it names the problem |
| 3 | the model could not produce a usable decision | show the raw reply to the human; do **not** write the ticket yourself |
| 4 | a budget or a stall was hit with layout paths unclaimed | show which paths; the human decides whether to raise `--max-tickets` or restart with a different layout |

## If you have to intervene

The single-step commands still exist, for repair and for resuming by hand. Use
them only when `plan` has stopped and the human has asked for something specific.

```
python3 $P3/p3-plan.py status | list | next | render T3
python3 $P3/p3-plan.py add --id T6 --title "..." --priority 3 \
        --files src/x.py,tests/test_x.py --blocked-by T1 \
        --acceptance "pytest -q tests/test_x.py" --goal "..." --details "..."
python3 $P3/p3-plan.py emit --all
python3 $P3/p3-plan-lint.py --ledger plan/tickets.jsonl
python3 $P3/p3-plan-lint.py --repo owner/name --parent N
```

`add` applies exactly the rules the loop applies, so a row it refuses is a row
the loop would have refused too. **The ledger is append-only**: a mistake is
corrected by a new ticket or by telling the human, never by rewriting history.

## Configuration

Defaults are right for the sandbox; change them only when asked.

| Flag / variable | Default | What it is |
|---|---|---|
| `P3_MODEL_URL` | `http://ollama-gate:11434/v1/chat/completions` | the planning model's endpoint (from the host: `http://127.0.0.1:11434/...`) |
| `P3_MODEL` | `gpt-oss:20b-64k` | model tag |
| `--retries` / `P3_MODEL_RETRIES` | 3 | retries after a rejected reply, before stopping loudly |
| `--max-tickets` | 30 | hard budget; hitting it with paths unclaimed is exit 4 |
| `--max-stalls` | 3 | consecutive tickets claiming no new path before giving up |
| `--max-files` | 4 | one concern per ticket, measured in files |
| `--dry-run` | off | render issues to `plan/fixtures/` instead of creating them |
| `--spec-file` / `--readme-file` | — | plan offline from files instead of fetching |

The inference call deliberately bypasses `HTTPS_PROXY`: the model gate is an
internal host, and sending inference through the egress allowlist would be denied
and look exactly like "the model is down".

## Pitfalls

1. **Issue numbers do not exist until step 5.** Tickets reference each other as
   `T1`; the emitter substitutes the real `#N`.
2. **`status:todo` is never yours to apply**, not even for a ticket you are sure
   about. Same for merging, and for editing the target README.
3. **Missing labels look like an auth error.** If step 5 complains about labels,
   the target repo was not bootstrapped.
4. **Exit 3 is not a prompt to help.** The script stopped because it could not get
   an answer. Supplying the answer yourself is the failure this design exists to
   prevent.
5. **Re-running is the fix for an interrupted run**, not starting a new plan
   directory.

## Verification

- [ ] `p3-plan.py plan ...` exits 0
- [ ] its step [6/6] validator run reports `0 failed`
- [ ] `p3-plan.py status` reports `pending=0` and full layout coverage
- [ ] every issue is `status:backlog` with exactly one priority, and the human has
      been told which tickets are in the first wave

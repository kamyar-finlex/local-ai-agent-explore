---
name: orchestrator-planner
description: "Decompose a spec issue into contract-conforming tickets."
version: 0.1.0
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
schedule and a worker can finish alone. You write no application code and you
approve nothing; you produce tickets and a human decides which of them start.

The work is done in small steps against a ledger on disk, one ticket per tool
call. That is not a style preference: a long single completion degrades near the
end, and a plan that exists only in this conversation is lost when the context
is. `p3-plan.py` renders the issue format for you, so your job is judgement --
what the tickets are -- not markdown.

## When to Use

- A target repository has an open issue labelled `spec` and no implementation
  issues yet.
- A previous planning run stopped part-way and must be resumed.
- Don't use for: writing application code, approving tickets (`status:todo` is a
  human act), editing the target README, or re-planning a spec that already has
  children -- add tickets to the existing ledger instead.

## Prerequisites

- `TARGET_REPO` (`owner/name`) and the spec issue number.
- `GITHUB_TOKEN` in the environment, injected at runtime. Never print it, never
  write it to a file, never put it in an issue body.
- `HTTPS_PROXY` pointing at the egress proxy — the agent has no direct route out.
- The contract's labels already exist in the target repo (`bootstrap-labels.sh`).
  A missing label surfaces as a permissions-looking error at emit time.
- Scripts live beside this skill; set the prefix once per session:
  `P3="${HERMES_HOME:-$HOME/.hermes}/skills/autonomous-ai-agents/orchestrator-planner/scripts"`

## Quick Reference

```
python3 $P3/p3-plan.py init --repo owner/name --spec N
python3 $P3/p3-plan.py spec-show
python3 $P3/p3-plan.py layout --path a/b.py,tests/test_b.py
python3 $P3/p3-plan.py add --id T3 --title "..." --priority 2 \
        --files src/x.py,tests/test_x.py --blocked-by T1 \
        --acceptance "pytest -q tests/test_x.py" \
        --goal "..." --details "..."
python3 $P3/p3-plan.py list | status | next | render T3
python3 $P3/p3-plan.py emit --all
python3 $P3/p3-plan-lint.py --ledger plan/tickets.jsonl
python3 $P3/p3-plan-lint.py --repo owner/name --parent N
```

## Procedure

**Run this first, before anything else, exactly as written:**

```
terminal(command="export P3=\"$HERMES_HOME/skills/autonomous-ai-agents/orchestrator-planner/scripts\"; python3 $P3/p3-plan.py init --repo \"$TARGET_REPO\" --spec \"$SPEC_ISSUE\"")
```

`TARGET_REPO`, `SPEC_ISSUE`, `HERMES_HOME` and the token are **already in your
environment**. Do not ask which repository or which issue — reading them is the
first command's job. If one is genuinely empty the command fails and says which,
which is the only reliable way to find out.

### Do not, before or during this

- **Do not ask the human which repo or issue.** It is `$TARGET_REPO` / `$SPEC_ISSUE`.
- **Do not clone the target repository.** `spec-show` fetches the issue and the
  README for you. A clone tells you nothing extra and costs turns.
- **Do not explore the filesystem** — no `git status`, no `grep` for the project,
  no reading `pyproject.toml`. You are planning a project that does not exist yet;
  there is nothing on disk to find.
- **Do not use `jq`** — it is not installed. `curl | jq` fails with exit 127, which
  looks like a network error and is not one.
- **Do not conclude the network is blocked.** Egress is proxied and works for
  `github.com` and `api.github.com`. If a command fails, read the actual error
  before diagnosing; a missing binary and an unreachable host look alike from a
  pipeline's exit code.
- **Do not write issue bodies yourself.** `p3-plan.py` renders them. Your output is
  fields, not markdown.
- **Do not write any application code. Not one file.** You are planning the project;
  workers implement it. The paths under `Files touched` describe what a worker will
  create — writing them yourself means the tickets describe work already done, and
  the code lands in the agent's own directory rather than the target repository,
  where it is useless to everyone. If you catch yourself creating `__init__.py` or a
  test, stop: that is a worker's ticket, not your job.
- **Do not verify anything by running it.** There is no code yet. An acceptance
  command that fails today is correct — it is what a worker makes pass.
- **Do not stop after one ticket and ask the human for the rest.** Planning the whole
  spec is the task. One ticket is not a plan.

### You are finished when, and only when

`p3-plan.py status` reports **`pending=0`** and every path in the recorded layout is
created by exactly one ticket. Until then you have a partial plan, not a plan.
Emitting is the last step and it is yours to run — not something to hand back with
instructions for someone else to finish.

Each step below ends with a criterion you can check. Do not start the next step
until it holds.

1. **Open the plan.** The command above. *Done when* the ledger path is printed.
   If it says the plan already exists, you are resuming: run
   `python3 $P3/p3-plan.py status` and skip to the step it names.

2. **Read the specification once.** `terminal(command="python3 $P3/p3-plan.py spec-show")`
   saves the spec issue and the target README under `plan/`. Read the README with
   `terminal(command="cat plan/readme.md")` if the spec references it. *Done when* you can name the project's
   language, its test runner, and every distinct behaviour the spec asks for.
   If the spec does not say enough to choose a file layout, stop and comment on
   the spec issue asking the human — do not invent a project.

3. **Choose the file layout.** Decide the whole set of files the finished project
   has, then record it: `p3-plan.py layout --path ...`. *Done when* every
   behaviour from step 2 maps to exactly one source file, and every source file
   has one test file. See *Choosing the file layout* below.

4. **Write the tickets, one per tool call.** One `add` per turn, in dependency
   order, blockers before dependants. The command validates the row and refuses
   bad ones; fix and re-issue the same call. *Done when* every path in the layout
   is created by exactly one ticket.

5. **Validate before creating anything.** `p3-plan-lint.py --ledger plan/tickets.jsonl`.
   *Done when* it exits 0. Fix by adding corrected tickets or, for a row that is
   wrong beyond repair, tell the human — the ledger is append-only by design.

6. **Emit.** `p3-plan.py emit --all` creates one issue per ticket, links it as a
   sub-issue of the spec, and records the number. If it dies part-way, run it
   again: it skips what the ledger says exists. *Done when* `status` reports
   `pending=0`.

7. **Verify what actually exists** with `p3-plan-lint.py --repo $TARGET_REPO --parent N`,
   then report to the human: ticket count, the wave list the validator prints,
   and that everything is `status:backlog` awaiting their approval. *Done when
   the validator exits 0.* A plan that does not validate is not finished work.

## Judgement calls

### Sizing a ticket

A worker must finish in a handful of turns, having read only the target README
and this one issue. Split when any of these is true:

- the Goal sentence needs an "and"
- more than four files, or more than one source file plus its test
- you cannot name the functions or classes the worker will write
- one command cannot prove it is done

Many small tickets is the mechanism that makes a small model useful here. Ten
tickets that each pass are worth more than four that each half-fail.

### Choosing the file layout

The project may not exist yet; choosing where its code lives is part of planning.

- Follow the conventions of the stack the README names, and nothing more
  ambitious. A flat `src/<package>/` with `tests/test_<module>.py` mirroring it
  is almost always right.
- **One concern per file.** Files are the unit of concurrency: two concerns in
  one file means two tickets that cannot run at the same time.
- **No `utils` file.** A file with no single owner attracts edits from every
  ticket and serialises the whole plan.
- Name the wiring file explicitly (the entrypoint that assembles the parts) and
  expect exactly one late ticket to own it.
- Record the layout before writing tickets, and never introduce a path later that
  is not in it. Path drift (`src/app.py` in ticket 3, `app/main.py` in ticket 7)
  is the failure this step exists to prevent.

A worked example of a layout and the five tickets that build it:
`references/worked-example.md`.

### Sequencing the foundation

No human prepares the ground. The plan starts with it, concretely:

- **T1** creates the dependency manifest, the test-runner config and one trivial
  test. Its acceptance command is the test runner. Every other ticket is blocked
  by it, directly or transitively.
- **T2** creates the package entrypoint module, so no later ticket has to create
  it and none of them race to.
- Never write a ticket called "set up the project". Name the file, say what it
  must contain, give the command that proves it.

### Keeping concurrently dispatchable tickets off each other's files

The dispatcher will not start two tickets that share a file — so an overlap does
not corrupt anything, it just stalls the plan, and it is counted as a planning
defect. The rule that prevents it:

**One file, one owner.** Each path in the layout is created by exactly one
ticket. A ticket that must change a file it does not own is `--blocked-by` the
owner. There is no other remedy.

For a file several tickets genuinely need — the entrypoint, a route registry —
make a single wire-up ticket blocked by all of them, and let it do the edits.

`add` refuses an overlapping row and names the ticket that already claimed the
path. When that happens, chain the tickets or move the change into the owner. Do
not "fix" it by dropping the path from `--files`: that hides the collision from
the dispatcher, which is the one component that could have caught it.

### Writing the acceptance command

One command, run from the repository root, exiting 0 only when the ticket is
done. Name the specific test file the ticket creates — `pytest -q` over the whole
suite passes for reasons that have nothing to do with this ticket. No `&&`, no
prose, no tool the README does not sanction. If the check genuinely needs two
steps, the ticket should commit a make target or a script and name that instead.

### Priority

`priority:1` foundation, `priority:2` the behaviour the spec is actually about,
`priority:3` wiring and secondary behaviour, `priority:4` the rest. Priority is
the human's reading order and the dispatcher's tie-break. It does **not** sequence
work — `Blocked-by` does. Never express a dependency as a priority.

## Context discipline

- One ticket per turn. Never batch several `add` calls into one command.
- The spec is on disk after step 2; re-read it with `cat plan/spec.md`
  rather than restating it in the conversation.
- `--details` is 40–80 words and points at README section names instead of
  copying them.
- Lost the thread? `status`, `next`, `list` — three short outputs that rebuild
  your place without re-reading the specification.
- Never read `plan/fixtures/`. Rendered bodies are output, not input.

## Pitfalls

1. **Issue numbers do not exist until emit.** Always use local ids (`T1`) in
   `--blocked-by`; the emitter substitutes the real `#N`.
2. **A refusal from `add` is the system working.** Correct the row; do not work
   around the check.
3. **Emitting out of order fails** — a ticket cannot reference a blocker that has
   no number yet. `emit --all` orders them for you.
4. **`status:todo` is never yours to apply**, not even for a ticket you are sure
   about. Same for merging, and for editing the target README.
5. **The ledger is append-only.** A mistake is corrected by a new ticket or by
   telling the human, never by rewriting history.
6. **Missing labels look like an auth error.** If emit complains about labels,
   the target repo was not bootstrapped.

## Verification

- [ ] `p3-plan-lint.py --ledger plan/tickets.jsonl` exits 0 before emitting
- [ ] every path in the recorded layout is created by exactly one ticket
- [ ] `p3-plan.py status` reports `pending=0` after emitting
- [ ] `p3-plan-lint.py --repo $TARGET_REPO --parent N` exits 0
- [ ] every issue is `status:backlog` with exactly one priority, and a human has
      been told which tickets are in the first wave

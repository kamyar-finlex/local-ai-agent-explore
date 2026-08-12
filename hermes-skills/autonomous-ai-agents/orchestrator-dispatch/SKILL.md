---
name: orchestrator-dispatch
description: "Dispatch approved tickets to worker containers."
version: 0.1.0
author: local-ai-agent-explore
license: MIT
platforms: [linux, macos]
metadata:
  hermes:
    tags: [Dispatch, Orchestration, Workers, GitHub, Issues]
    related_skills: [orchestrator-planner]
---

# Orchestrator Dispatch

Hand approved tickets to worker containers, several at once.

**You do not decide anything here.** Readiness is arithmetic and the script owns
it: a ticket runs only when a human has approved it, its blockers are closed, and
its declared files do not collide with anything already in flight. Your job is to
run one command and report what came back honestly — including when the answer is
"nothing was ready".

That division is deliberate. "Is this ticket ready" has to be right every single
time, and a model that can be argued into dispatching a blocked ticket destroys
the review gate the whole workflow rests on.

## When to Use

- A human has moved one or more tickets to `status:todo` and work should start.
- Someone asks what is ready, or why a particular ticket has not started.
- Don't use for: approving tickets (`status:todo` is a human act — see the
  prohibitions below), planning (that is `orchestrator-planner`), or merging.

## Prerequisites

Already in your environment; you do not need to ask for any of them:

- `TARGET_REPO` and `GITHUB_TOKEN` — the repository and its credential.
- `DISPATCH_TOKEN` — the bearer for the spawn dispatcher, reachable on the
  isolated network as `hermes-dispatcher:2375`.

## Procedure

**Run this first, exactly as written:**

```
terminal(command="export P4=\"$HERMES_HOME/skills/autonomous-ai-agents/orchestrator-dispatch/scripts\"; python3 $P4/p4-dispatch-loop.py plan")
```

`plan` changes nothing: no labels, no containers. It prints what it *would*
dispatch and, for everything it skips, the reason. Read that output to the human
before doing anything else — if a ticket they expected is missing, the reason is
already on screen.

Then, only if there is something to dispatch:

```
terminal(command="python3 $P4/p4-dispatch-loop.py dispatch")
```

That claims each ready ticket, relabels it `status:in-progress`, and asks the
spawn dispatcher for one worker container per ticket. Report the container names
and the ticket numbers.

To check on work already running:

```
terminal(command="python3 $P4/p4-dispatch-loop.py reap")
```

### Do not

- **Do not decide a ticket is ready.** If the script skipped it, it is not ready,
  whatever the ticket looks like to you.
- **Do not relabel anything to `status:todo`.** Approval is a human act. An agent
  that approves its own work has removed the only gate in this system.
- **Do not merge a pull request**, ever.
- **Do not edit tickets** to make them dispatchable. A ticket the script calls
  malformed is a planning defect: report it and stop.
- **Do not write application code.** Workers do that, in their own containers.
- **Do not re-run `dispatch` because nothing appeared to happen.** Claims are
  recorded on the issue; a second run may be refused, and that refusal is correct.

## Reading the output

`plan` prints one line per ticket. Common skip reasons and what they mean:

| Reason | What to tell the human |
|---|---|
| not approved | still `status:backlog`; they need to move it to `status:todo` |
| blocker #N is open | working as designed — #N must close first |
| files overlap #N | the two tickets touch the same file, so they cannot run together |
| malformed | a planning defect; quote it and stop |

Nothing ready is a normal outcome, not a failure. Say so plainly rather than
looking for something to do.

## Verification

- [ ] `plan` ran and its output was reported before anything was dispatched
- [ ] every dispatched ticket was `status:todo` with all blockers closed
- [ ] no ticket was relabelled to `status:todo` by you
- [ ] container names and ticket numbers reported back to the human

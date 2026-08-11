# Orchestrator contract

The rules the planning agent, the dispatch loop and the worker agents all follow.
Kept in one file because they have to agree exactly: if the planner writes
`Blocked-by:` and the dispatcher looks for `Blocks:`, dependency handling silently
never fires and every ticket looks ready.

This file describes *how* work is planned and executed. It says nothing about *what*
is being built — that lives in the target project's own README, which the planner
reads as its specification.

## Roles

**Planner** — reads the target project's README and one spec issue, decomposes the
work into implementation issues, assigns each a priority, and declares dependencies.
Writes no application code.

**Dispatcher** — polls for approved issues, works out which are actually ready, and
starts a worker container per issue. Contains no model; it is plain code, so that
"is this ticket ready" is deterministic and auditable rather than a judgement call.

**Worker** — takes exactly one issue, implements it on its own branch, runs the
issue's acceptance command, and opens a pull request. Knows only the target README
and its own issue.

**Human** — approves and merges. Nothing else.

## Ticket state — labels are the source of truth

Not the project board. A board may mirror this for visibility (GitHub's built-in
auto-add workflow does it without any code), but nothing reads the board.

| Label | Meaning | Who sets it |
|---|---|---|
| `spec` | This issue is a specification to plan from | Human |
| `status:backlog` | Awaiting human approval. **Never dispatched.** | Planner, on creation |
| `status:todo` | Approved. Eligible for dispatch. | **Human only** |
| `status:in-progress` | Claimed by a worker | Dispatcher |
| `status:blocked` | Has at least one open `Blocked-by` | Planner or dispatcher |
| `status:done` | Its pull request was merged | Human, or a merge automation |
| `priority:1` … `priority:4` | 1 is highest | Planner |

The swap from `status:backlog` to `status:todo` is the **only** thing that starts
work. An agent that relabels its own issue has defeated the review gate, so that is
prohibited below rather than merely discouraged.

## Ticket format

Every issue the planner creates uses this body:

```
## Goal
One sentence describing the outcome.

## Files touched
- path/to/file
- path/to/its/test

## Details
What to implement. Reference the section of the target README that specifies it
rather than restating it.

## Acceptance criteria
<a single runnable command>

## Blocked-by
#12
#13
```

- **Files touched** is a list of paths, one per line, prefixed `- `. The dispatcher
  parses it to detect overlap.
- **Acceptance criteria** is one shell command, nothing else. Prose here makes the
  ticket unverifiable and is a planning defect.
- **Blocked-by** lists issue numbers, one per line, `#N`. Omit the section entirely
  when there are no blockers — do not write "none".

## Planning rules

**One concern per ticket.** A worker should finish in a handful of turns. If it
plausibly cannot, split it. Preferring many small tickets over few large ones is the
entire mechanism by which small models handle a large project — it is not a style
preference.

**Every ticket names the files it touches.** No exceptions; a ticket without a file
list cannot be scheduled safely.

**Tickets that may run at the same time must not share a file.** Two workers editing
one file will collide, and that is a *planning* failure. Where several tickets must
touch the same file, chain them with `Blocked-by` instead.

**Declare dependencies rather than relying on priority.** Priority orders what a
human should care about; `Blocked-by` is what the dispatcher enforces. If B needs
what A creates, say so explicitly.

**Scaffolding is planned like any other work.** No human prepares the ground first.
Foundation tickets must be concrete — which file, what it must contain, which command
proves it — because "set up the project" is not something a small model can act on.

**Tests belong to the ticket that creates the code**, not to a separate testing
ticket.

**Every ticket must be workable standalone**, by a worker that has read only the
target README and that one issue.

## Dispatch rules

A ticket is dispatched only when **all** of these hold:

1. It carries `status:todo`.
2. Every issue listed under `Blocked-by` is closed.
3. Its `Files touched` list does not intersect that of any ticket currently
   `status:in-progress`.
4. It has a parseable `Acceptance criteria` command.

Otherwise it is skipped and left for the next poll. A ticket failing rule 2 or 3 is
normal and expected; a ticket failing rule 1 or 4 should be reported, because it
means the planner produced something unusable.

Ready tickets are dispatched in priority order, then by issue number.

## Worker contract

- Branch from the default branch as `issue-<number>-<short-slug>`.
- Change **only** the files listed under `Files touched`. If the work genuinely needs
  another file, comment on the issue saying which, and stop.
- Run the acceptance command. It must pass before opening a pull request.
- Run the project's full test suite. It must also pass.
- Open a pull request whose body references the issue as `Closes #N`.
- Add no dependency the target README does not already sanction.

## Validation, before a worker's PR is considered done

The dispatcher checks:

- the acceptance command passes on the branch
- the diff touches only the declared files
- the full test suite passes
- a pull request exists and references the issue

A failure here is recorded on the issue. The dispatcher does not fix the work
itself — an agent silently repairing another agent's output would hide exactly the
failure modes this experiment is meant to surface.

## Hard prohibitions

No agent may ever:

- **merge a pull request** — humans merge
- **move an issue to `status:todo`** — approval is a human act, and an agent doing it
  removes the review gate entirely
- **modify the target project's README**, or another issue's description
- **change files outside its ticket's declared list**
- **commit to the default branch, or force-push anything**
- **weaken, skip or delete a test to make a run pass** — a failing test is the most
  useful output this system produces
- **add a dependency** the target project's README does not sanction

The first two are enforced outside the agent, not by instruction: a token scoped
without merge permission, and branch protection on the default branch. Anything
enforced only by a prompt is a guardrail against accident, not a control — a lesson
this project learned the hard way when an agent was refused a `/tmp` write by its own
tool allowlist and then wrote there through the shell moments later.

## Credentials

Workers receive a token scoped to the target repository alone, permitting issues,
contents and pull requests — and **not** `gist`, which is an exfiltration channel a
domain allowlist cannot see. It is injected at runtime from an ungitignored local
file and never committed, never logged, never printed in harness output.

The planner needs issue write access. The dispatcher needs to read issues and
labels. Neither needs project-board scope, since labels are the source of truth.

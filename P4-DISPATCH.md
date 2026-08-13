# The dispatch loop

The component that decides which tickets are ready and starts a worker
container for each, several at once. It implements `ORCHESTRATOR.md` — *Ticket
format*, *Dispatch rules*, *Worker contract*, *Validation*, *Hard prohibitions* —
and it contains no model, on purpose.

> `./verify-dispatch.sh` — **85 checks, 0 failures**, against committed fixtures;
> **92 with `spawn`**, which adds a real worker container created through
> `p1-dispatcher` from an orchestrator that has no Docker socket.
>
> One pass of this loop has since produced **three workers alive at the same
> instant**, and refused a fourth ticket that declared a file one of them held.
> The timestamps, the diffs and the refusal are in
> [PARALLEL-RUN.md](PARALLEL-RUN.md), checked by `./verify-parallel.sh`.

| File | Purpose |
|---|---|
| `p4-dispatch-loop.py` | The loop: `plan` / `dispatch` / `reap` / `validate`. Stdlib only. |
| `p4-worker-instructions.md` | What a worker agent is told when handed one issue. |
| `verify-dispatch.sh` | PASS/FAIL harness, fixtures not live GitHub, non-zero exit. |
| `p4-fixtures/*.json` | The repository states the harness schedules against. |

## Why readiness is code and not a judgement

"Is this ticket ready" is asked on every poll, about every ticket, forever. A
model answering it is wrong occasionally and unaccountably; two workers then edit
one file and the damage looks like a merge conflict rather than a scheduling bug.
So readiness here is arithmetic over labels, issue states and declared paths:

```
ready(t) ⟺ open(t) ∧ spec ∉ labels(t) ∧ status:done ∉ labels(t)
         ∧ no un-released claim on t
         ∧ ∀ b ∈ blocked_by(t): state(b) = closed
         ∧ files(t) ∩ files(h) = ∅  for every held ticket h
         ∧ t parses: a file list and exactly one acceptance command
```

Ordering is `(priority, issue number)`, both from the issue itself. The output of
a pass is a JSON plan listing what was dispatched, what was skipped **with the
reason**, and every parse defect — so a scheduling decision can be replayed and
audited months later without the repository being in that state any more.

`plan` is read-only and mutates nothing, which makes "what would you do right
now" a safe question to ask in production.

## What a pass does

```
poll ──► parse every issue body ──► build plan ──► claim ──► spawn ──► relabel
             │                          │            │         │
             │ defects reported         │ cycles     │ comment  └ p1-dispatcher /spawn
             │ as issue comments        │ reported   │ election      (no Docker socket here)
             ▼                          ▼            ▼
        planner sees them          deadlock is    only one dispatcher
        instead of silence         visible        can win a ticket
```

`reap` runs FIRST in that pass, before the plan is built, releasing the claims of
workers that have stopped — otherwise a dead worker's claim makes this very pass
skip its ticket. `validate` checks a finished worker's output, separately.

## Claiming: the lock is a comment, not a label

GitHub has no compare-and-swap on labels. Two dispatch passes can both read a
ticket as ready and both relabel it; the second write silently wins and two
workers edit the same files. Three layers close that, weakest first:

1. **One pass per host.** `flock` on `P4_LOCK`. A second pass exits 3 without
   acting. This is what stops the overwhelmingly common case: a cron poll
   overlapping a slow previous poll.
2. **Re-read immediately before acting.** The candidate's labels are fetched
   again at claim time, so most of the read/act window is gone.
3. **An election on server-assigned ids.** The dispatcher posts a claim comment
   carrying a nonce, then re-lists the comments. The **earliest un-released claim
   comment wins** — and "earliest" is GitHub's own monotonically increasing
   comment id, not our clock and not our ordering. A dispatcher that finds
   someone else's claim below its own withdraws its comment, spawns nothing and
   leaves every label untouched.

That last layer is what makes the claim atomic across *machines*, not just
passes, without a lock service. The harness tests it by having the fixture insert
a competitor's claim, with a lower id, at the exact moment our claim is written —
the interleaving a read-then-write check cannot see.

**Order of operations is deliberate: elect → spawn → relabel.** If the spawn
fails, the dispatcher posts a release marker and stops with the ticket's labels
exactly as it found them. Relabelling only after a container exists is what keeps
`status:in-progress` meaning "a worker is running" rather than "a dispatcher
intended one to".

Consequently the **claim comment is the lock and the label is its mirror**. A
ticket is treated as held if it has either. That is deliberate redundancy: a
hand-labelled `status:in-progress` still reserves its files, and a claim posted
milliseconds before a crash still blocks a second dispatch.

## Stale claims: a dead worker must not hold a ticket forever

**The dispatcher asks the container.** For most of this project's life it could
not: the spawn interface was three verbs and exposed no inventory, no `/logs`
and no `/wait`, so liveness had to be inferred from silence. A worker that failed
in thirty seconds held its ticket for the next forty-five minutes, and the
workaround — `reap --timeout 0` — releases *every* claim past zero minutes,
including a live worker's, so it cannot be run while anything else is working.
One session needed it six times.

The fix was to add exactly the one fact the reaper needs and nothing more:
[`/status`](SPAWNING-DECISION.md), which takes **one** container name and answers
running / exited / gone. Not a list, not an inspect, not an inventory. The five
cases, and the order is the design:

| | Signal | What happens |
|---|---|---|
| 1 | an **open PR** references the issue | never reaped, whatever the container says |
| 2 | container **exited** | released immediately, reason `worker_exited`, exit code recorded |
| 3 | container **gone**, claim older than `P4_SPAWN_GRACE_MINUTES` | released, reason `container_gone` |
| 4 | container **gone**, claim younger than that | left alone |
| 5 | **running**, or liveness **unknown** | the old clock, unchanged |

**The open-PR test is first, and that is not an optimisation.** A worker that
exits 0 has finished and its container stops within seconds — but its files must
stay reserved until a human *merges*, or a second worker starts editing files an
unmerged branch still changes and the conflict lands on the human at merge time.
Move that test below the status test and every successful ticket is released the
moment it finishes.

**The grace period exists because the claim is written before the container.**
The order is elect → spawn → relabel, so for a second or two a perfectly healthy
claim has nothing to inspect. Without the grace period a reaper racing a
dispatcher takes the ticket away from a worker that is still being born. An
*exited* container needs no grace: that answer is unambiguous.

**Unknown never means dead.** A dispatcher too old to have the verb, or a network
blip, returns unknown, and the reaper falls back to the clock. The one thing a
component deciding whether to take work away from a running agent must not do is
treat "I could not tell" as "it is dead".

**A running worker is still subject to the timeout.** Tempting to exempt it now
that the fact is available — the old note here complained that a slow, quiet
worker gets killed under this rule — and wrong: a wedged container never exits,
so an exemption trades a rare wrong kill for a ticket stuck forever with no
recovery but a human and a shell. What changed is that the clock is no longer the
*only* signal, not that it is gone.

**Why the worker does not release its own claim.** It looked like the obvious
fast path, and the ticket suggested it. Releasing is two halves — drop the claim
comment and drop the `status:in-progress` label — because a ticket is held if it
has *either*. `worker.py` has no label call at all, by design, so a self-release
would clear the lock and leave the mirror, and the ticket would still be skipped
as held. A half-release is not a release.

Reaping stops and removes the container through the spawn dispatcher, posts a
release marker explaining what happened, and moves the ticket back to
**`status:backlog`** so that its state stops claiming a worker is running.

**Reaping now runs first, and by default.** `dispatch` reaps before it plans, not
after: a dead worker's claim is exactly what makes the next pass skip its ticket
as `already_claimed`, so releasing it afterwards means the release only takes
effect on the pass after this one — and a human asking twice was the whole
friction. `--no-reap` opts out; `--reap` is still accepted and is now a no-op.

### Measured, live

A ticket in `premium-toolkit-demo` written to fail on purpose. Its worker exited
**1** thirty-five seconds in (the model declined to add an unsanctioned
dependency, so nothing was staged). One dispatch pass, twenty-two seconds later,
with no `--timeout` override and nothing removed by hand:

```
container BEFORE:  hermes-worker-11  Exited (1) 21 seconds ago

T=14:13:04
reap   # 11 released  container=exited   reason=worker_exited  exit_code=1
reap   #  4 none      container=-        reason=PR #10 is open and awaiting a human
claim  # 11 claimed=True -> hermes-worker-11
T=14:13:18  (pass complete)

container AFTER:   hermes-worker-11  Up 2 seconds
```

Fourteen seconds, on a claim ninety seconds old, where the old behaviour was
forty-five minutes and two manual commands. The `#4` line in the middle is the
control that makes the release mean something: in the same pass, a claim whose
worker had *also* exited was kept, because a human has not merged its pull
request yet.

Note what that no longer does. With the approval gate removed, `status:backlog`
withholds nothing — the ticket is immediately dispatchable again. What still
prevents a broken ticket burning twenty containers overnight is that **the
reaper never re-dispatches**: it releases, and the next run happens because a
human asked for it, not because a loop retried.

Two exceptions keep the reaper from destroying good work:

- **An open PR referencing the issue is never reaped.** Its files stay reserved.
- **A recent heartbeat overrides an old claim.** The harness has a 210-minute-old
  claim with a 2-minute-old heartbeat and requires it to survive.

The same asymmetry appears after validation: a ticket that **passes** stays
`status:in-progress` until a human merges. The file lock must be held until
**merge**, not until PR-open — otherwise a second worker starts editing files
that an unmerged branch still changes, and the conflict lands on the human at
merge time. A ticket that **fails** validation goes to `status:backlog` and
releases its files, because nothing is going to merge.

## File overlap: what counts as a collision

Exact path matching is the start; two refinements were added deliberately.

| Case | Verdict | Why |
|---|---|---|
| `src/api.py` vs `src/api.py` | **conflict** | the obvious one |
| `src/api.py` vs `./src/api.py` | **conflict** | paths are normalised first |
| `docs/` vs `docs/guide.md` | **conflict** | a ticket declaring a directory owns everything in it; directory-level work (moves, renames, an index file) collides with edits inside it |
| `src/App.py` vs `src/app.py` | **conflict** | compared case-folded: on macOS and Windows these are one file, and two workers editing them corrupt each other at checkout |
| `src/a.py` vs `src/b.py` | **no conflict** | siblings run in parallel — this is the entire point of declaring files per ticket |

Sibling files in one directory are explicitly *not* a conflict. Treating them as
one would make the file list pointless and serialise the whole project.

Where the dispatcher cannot prove disjointness it **fails closed**: if any held
ticket declares no parseable file list — only reachable by a human hand-labelling
something `status:in-progress` — the pass dispatches *nothing* and says why.
Refusing to schedule is recoverable; scheduling two workers onto one file is not.

## Defects are reported, never silently skipped

`ORCHESTRATOR.md` distinguishes skips that are normal (blocked, file conflict)
from skips that mean the planner produced something unusable. The second kind is
posted as a comment on the issue, once per defect kind (marker-deduplicated, so a
60-second poll does not become a comment flood):

| Defect | Meaning |
|---|---|
| `files_missing` / `files_empty` | no file list — unschedulable by construction |
| `files_bad_path` | absolute path or `..` escape |
| `acceptance_missing` / `acceptance_multiline` | zero or several commands where the contract requires exactly one |
| `acceptance_prose` | a sentence, not a command — the ticket is unverifiable |
| `blockedby_unparseable` | a `Blocked-by` section with no `#N` (e.g. the "none" the contract forbids) |
| `blockedby_self`, `dependency_cycle` | a ticket that can never become ready |
| `blocker_unknown` | `Blocked-by` points at an issue that does not exist |
| `in_progress_unknown_files` | a held ticket whose files cannot be determined |
| `files_annotated`, `priority_missing` | advisory: reported, still schedulable |

Prose detection is three deterministic rules, not a model: a command does not end
in a sentence-final full stop (`pytest .` does not trip it — the dot is preceded
by a space), does not contain two or more prose-only stopwords outside quotes,
and its first token must look executable. False positives are possible and safe:
every rejection is *reported on the issue*, so a wrongly rejected ticket is
visible in seconds rather than silently never scheduled.

A cycle is found with an iterative DFS bounded by the edge count. Readiness never
walks the graph at all — it only asks "is that one issue closed" — so a cycle
cannot hang the loop even if cycle detection did not exist; detection exists so
the deadlock is *reported* instead of looking like ordinary blocked work.

## Validation of a finished worker

Per the contract, four checks, and no repairs:

1. a pull request exists and references the issue (`Closes #N`, or an
   `issue-<N>-…` head branch),
2. `git diff --name-only <merge-base>..<branch>` touches only declared paths,
3. the ticket's acceptance command exits 0 on that branch,
4. the project's full test suite exits 0 (`P4_TEST_COMMAND` — the suite command
   belongs to the repository, not to a ticket; if it is unset that counts as a
   **failure**, not a skip, because "we did not run the tests" must never read as
   a pass).

The result is written to the issue as a PASS/FAIL list. On failure the ticket
goes to `status:backlog` with the report attached and the dispatcher stops
touching it. It never edits the branch: an agent quietly repairing another
agent's output hides exactly the failure modes this experiment exists to surface.

## Spawning

One worker container per ticket, through the existing body-validating dispatcher
(`SPAWNING-DECISION.md` option (d)) — `POST /spawn {"name","cmd"}`. This program
never sees a Docker socket and never constructs a create body, so it cannot
widen a worker's privileges even if it wanted to.

Worker containers are named `<WORKER_NAME_PREFIX><issue>` — `hermes-worker-26`
in the composed stack. The prefix is not decoration: `p1-dispatcher` refuses any
name outside its own `WORKER_NAME_PREFIX`, so the two must agree exactly, and
they are fed from **one** compose variable for that reason. Two components each
with a defensible default disagreed once and every `/spawn` was refused, which
reads as a spawn failure rather than as a configuration mismatch. The harness
fixtures read the same variable.

Because the name is derived from the issue number, **every re-dispatch of an
issue wants the name its previous attempt still holds.** A finished container
keeps its name until it is removed, so the second attempt at an issue used to
fail `409 Conflict: name already in use` and needed a hand-run `docker rm` — the
second stale artefact per failure, alongside the claim. A 409 is now recovered:
the dispatcher asks `/status`, and **only if the namesake is positively not
running** removes it and retries the spawn exactly once. Never on unknown, never
on a running container, and never in a loop — "clear the old container" would
otherwise be a very direct way to put two workers on one issue.

Measured, live (`./verify-dispatch.sh spawn`, with `./p1-spawn-setup.sh` up):

```
LIVE SPAWN THROUGH p1-dispatcher  (opt-in: needs ./p1-spawn-setup.sh)
  PASS  the dispatch loop ran inside a container with no Docker socket (exit 0)
  PASS  a real worker container p1-p4w-31 exists
  PASS  it carries role=hermes-worker (the spawn dispatcher stamped it)
  PASS  it has no bind mounts - the hardened template still applies
  PASS  it is running
  PASS  no container for #30, the ticket this pass lost the claim race on
  PASS  cleanup: p4 worker containers removed
```

## What the harness proves

`./verify-dispatch.sh` runs against `p4-fixtures/`, never the network, and needs
no credential. Fixtures rather than a live repository because the scheduler must
be right *every* time, and because no live repo can be made to hold a dependency
cycle, a dead worker, a claim race and a case-only filename collision at the same
instant.

```
RESULT: 85 passed, 0 failed
```

Suites: scheduling (positive control first), what must never be dispatched,
malformed tickets, dependency cycles, the concurrency limit, fail-closed
behaviour, claiming, stale-claim recovery, worker-output validation, secret
hygiene. Every suite opens with a control that must succeed — **a dispatcher that
dispatches nothing satisfies every negative assertion in this file**, so
"something was dispatched, claimed, spawned and validated" is asserted first and
the run aborts if it fails.

The harness was itself checked by breaking the dispatcher on purpose and
confirming it goes red. Each of these mutations was applied to
`p4-dispatch-loop.py`, the harness re-run, and the code restored:

| Mutation | Harness result |
|---|---|
| `path_conflict` never matches | 6 failures (order, shared file, in-progress collision, case-fold, validation) |
| open blockers treated as closed | 3 failures (`#3`, `#27`, order) |
| claim election always won | 3 failures (claimed `#30`, spawned its worker, moved its label) |
| defects never recorded | 4 failures (three defect kinds, plus the issue comment) |
| reaper ignores the timeout | 3 failures (live worker `#21` reaped, heartbeat ignored, its container touched) |
| diff-scope check disabled | 2 failures (`#51` passes with an undeclared file) |
| cycle detection removed | 2 failures (no cycle reported, `#10` misreported as ordinary blocked) |
| concurrency limit ignored | 3 failures (both limits overrun, `no_slots` never reported) |
| host lock disabled | 1 failure (a second pass ran while the lock was held) |
| fail-closed removed | 3 failures (dispatched anyway, no reason, container spawned) |
| reaper leaves `status:in-progress` | 1 failure (label unchanged after release) |

The secret-hygiene suite carries a **negative control**: it first proves the grep
can find the token when it *is* present, then sweeps every file the run produced.
Without that control, "no token found" would also be what a broken grep reports.

## Failure modes that remain

**`GitHubClient` is now exercised against live GitHub, but only on the happy
paths.** It has run `plan` and `dispatch` against the real target repository
several times, including the three-worker run in `PARALLEL-RUN.md`, so issue
listing, comment listing, the claim election, the label add/remove endpoints and
comment deletion all work against the real API. What is still only fixture-tested
is everything that needs an unusual response: pagination past one page,
rate-limit backoff, and the PR listing shape the reaper reads. The harness cannot
provoke those, and the live runs have not been large enough to.

**The claim election costs API calls and is not free.** One `POST` plus one `GET`
per candidate, on top of one comment fetch per open issue per pass. On a large
repository with a 60-second poll this will meet the secondary rate limit. Backoff
is implemented; the real fix is a conditional-request/ETag cache, which is not
written.

**A claim race is decided by comment id, which assumes both dispatchers post.**
A dispatcher that spawns a worker *without* posting a claim comment — an older
version, or a hand-run `docker run` — is invisible to the election. The label
check catches it only after that dispatcher relabels.

**Reaping still cannot distinguish "wedged" from "slow and quiet".** It can now
tell *dead* from either — `/status` answers that — but a container that is
running and producing nothing looks identical whether it is thinking hard or
hung, and the 45-minute clock will still kill it. The heartbeat contract that
would narrow this lives in the worker's prompt, and a prompt is a guardrail
against accident, not a control — the same lesson `ORCHESTRATOR.md` records about
the `/tmp` write.

**A worker's own writes are unpoliced between claim and validation.** Nothing
stops a running worker from editing a file outside its list; the diff-scope check
catches it afterwards, at validation, and rejects the PR. Detection, not
prevention.

**Secret delivery to workers is unsolved by this component.** `p1-dispatcher`
builds the create body itself and injects no environment, so a worker cannot be
handed a token through `/spawn`. The issue number and repo travel in `argv`
(non-secret, deliberately). The token must reach the worker either baked into its
image — poor — or through a narrow, dispatcher-side `Env` allowlist added to
`p1-dispatcher.py`, which is the recommended fix and is not made here because
that file is explicitly not to be modified.

**Validation executes worker-authored code in the dispatcher's own process.**
`validate` runs the acceptance command and the test suite via `subprocess` in a
checkout. The spawn interface has no way to return a worker's exit status, so the
verification cannot currently be delegated to a throwaway container. Until it
can, run the dispatcher itself confined (that is what `README.md`'s cage is for)
and treat the checkout as untrusted.

**Directory-level declarations are coarse.** `docs/` blocks every ticket touching
anything under `docs/`. That is the safe direction, but a planner that declares
broad directories will serialise the project without any warning that it has done
so. Nothing reports "your file lists are too coarse to parallelise".

**Priority is trusted, not validated.** A planner that marks everything
`priority:1` gets issue-number order and no complaint.

**Nothing detects a ticket that is ready forever.** A ticket skipped 500 times for
`file_conflict` is invisible; there is no starvation metric. `held_issues` in the
plan output is the raw material for one.

**And nothing now stands between a prompt and a running worker.** Dropping the
approval gate made every open ticket dispatchable, which is what it was for — but
it also means a mistyped issue number, a misrouted skill call or a planner that
produced nonsense reaches a container without a human having looked at the ticket
in between. The pull request is the remaining gate, and it is the *last* one.

## Configuration

Everything is environment, and every machine-specific value belongs in
`local.env` (gitignored) — see `local.env.example`.

| Variable | Default | Meaning |
|---|---|---|
| `TARGET_REPO` | — | `owner/name` of the target repository |
| `TARGET_REPO_TOKEN` | — | repo-scoped token; read at runtime, never logged |
| `P4_MAX_CONCURRENCY` | `3` | workers in flight |
| `P4_WORKER_TIMEOUT_MINUTES` | `45` | silence before a claim is reaped — the backstop, no longer the mechanism |
| `P4_SPAWN_GRACE_MINUTES` | `2` | how long a MISSING container is forgiven after its claim is posted |
| `P4_POLL_INTERVAL` | `60` | seconds between passes with `--interval` |
| `P4_SPAWN_URL` / `P4_SPAWN_TOKEN` | `http://p1-dispatcher:2375` | the spawn dispatcher |
| `P4_WORKER_NAME_PREFIX` | `p1-p4w-` | must start with `p1-dispatcher`'s prefix |
| `P4_WORKER_CMD` | `sh -c 'P4_ISSUE=… …'` | JSON argv template; `cmd[0]` must be on the spawn allowlist |
| `P4_TEST_COMMAND` | — | the project's full suite, for validation |
| `P4_LOCK` | `$TMPDIR/p4-dispatch.lock` | the one-pass-per-host lock |

```bash
python3 p4-dispatch-loop.py plan --source github --limit 3        # read-only
python3 p4-dispatch-loop.py dispatch --source github --interval 60  # reaps first, by default
python3 p4-dispatch-loop.py validate --source github --issue 42 --checkout ./target
./verify-dispatch.sh                                              # 85 checks
./verify-dispatch.sh spawn                                        # + live containers
```

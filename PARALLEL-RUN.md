# The parallel run

The two Phase 1 criteria that were **not** met when TECH-98 closed: three worker
agents running concurrently, and no cross-agent collisions across a full parallel
run. Both are now met. This file is the evidence and the method, and it is
deliberate that the evidence comes first.

> `./verify-parallel.sh` — **25 checks, 0 failures**; **26 with `live`**, which
> re-queries the three pull requests from GitHub instead of replaying the
> capture; **48 with `mutate`**, a 22-case battery that breaks each claim in turn
> and requires the *right* check to go red.

## Why this needed its own ticket

Three workers had already run, and two had produced merged pull requests. The
claim "three concurrent workers, no collisions" was made twice on the strength of
that, and it was false both times:

```
hermes-worker-3   11:52:15 -> 11:52:54   exit 0
hermes-worker-4   12:10:10 -> 12:10:42   exit 0
hermes-worker-5   13:07:33 -> 13:08:04   exit 10
```

Eighteen minutes, then fifty-seven minutes apart. Not one overlapping second.
Each came from a separate human prompt after the previous ticket was reviewed and
merged. That demonstrates the worker path three times over and says nothing at all
about parallelism.

So the standard here is **intersecting container timestamps**, and nothing weaker.
Not the agent's account of itself, not the dispatcher's plan output, not a count
of containers in `docker ps -a`.

## The run

One prompt, at 08:49:43 UTC on 2026-08-13:

```
Dispatch the ready tickets in the target repository. Use your orchestrator-dispatch skill.
```

The agent loaded `orchestrator-dispatch`, ran `plan`, then `dispatch`, and reported
three containers. The prompt names the skill because
[the routing is unreliable when it does not](#what-this-does-not-prove) — that is a
separate problem, tracked in TECH-103, and this run does not pretend otherwise.

`docker inspect`, afterwards:

| Container | Started | Finished | Duration | Exit |
|---|---|---|---|---|
| `hermes-worker-26` | 08:50:50.172 | 08:52:55.791 | 125.6 s | 0 |
| `hermes-worker-27` | 08:50:53.937 | 08:52:17.605 | 83.7 s | 0 |
| `hermes-worker-28` | 08:50:57.382 | 08:53:11.875 | 134.5 s | 0 |

The last to start began 7.2 s after the first; the first to finish ended 38 s
before the last. **All three were alive together from 08:50:57.382 to
08:52:17.605 — 80.2 seconds of three-way overlap**, computed by the harness from
those timestamps rather than asserted here.

A second, independent witness: a `docker ps` sample taken once a second by a
process that knows nothing about the dispatcher recorded **74 consecutive samples
listing all three names**, spanning 79.0 s against the 80.2 s the container
timestamps claim — **agreement to 1.2 s**.

That agreement is asserted, not just observed, and it is the check that matters
most. The sequential-run check only looks in one direction: it catches a run that
did not overlap. It cannot catch a run whose windows were *widened* to
manufacture overlap that never happened, because a bigger intersection is exactly
what it is looking for. Requiring the two witnesses to describe the same event —
same duration to within one sample period, the sampled span contained in the
inspected window — means forging this needs two files edited into agreement
rather than one number changed. Tolerance is 3 s: one sample period plus the
latency of the `docker ps` the sampler shells out to.

```
08:50:57  1  hermes-worker-26
08:50:59  2  hermes-worker-26 hermes-worker-27
08:51:01  3  hermes-worker-26 hermes-worker-27 hermes-worker-28   <- 74 samples
08:52:18  2  hermes-worker-26 hermes-worker-28
08:53:12  0
```

## What made three possible, and it was not concurrency work

No scheduling code changed for this. The dispatcher has always dispatched every
ready ticket in one pass, up to `P4_MAX_CONCURRENCY`. What was missing was
**three unblocked, file-disjoint tickets existing at the same moment**, which the
plan shape at the end of Phase 1 did not naturally produce — its tickets chained
through `Blocked-by`, so at most one or two were ever ready together.

The three used here were written to be independent by construction: each creates
one new leaf module plus its test, each imports nothing from the other two, and
their file lists are pairwise disjoint.

| Issue | Files touched | Acceptance |
|---|---|---|
| #26 | `app/interests.py`, `tests/test_interests.py` | `pytest -q tests/test_interests.py` |
| #27 | `app/store.py`, `tests/test_store.py` | `pytest -q tests/test_store.py` |
| #28 | `app/summary.py`, `tests/test_summary.py` | `pytest -q tests/test_summary.py` |

That is the generalisable finding, and it is a **planning** result rather than an
infrastructure one: *the width of a parallel run is decided when the plan is
written, not when the dispatcher runs.* A planner that chains everything produces
a system that can run three workers and never does. Nothing currently reports
this — a ticket skipped five hundred times for `file_conflict` is invisible, and
so is a plan whose critical path is its whole length. See
[what this does not prove](#what-this-does-not-prove).

The other precondition was TECH-101 removing the approval gate. With it in place,
three tickets could only start together if a human flipped three labels in a
browser first; the backlog is now the run queue.

## No cross-agent collisions

Four independent things had to hold, and the harness checks each separately
because they fail differently.

**Three branches, none shared.** `issue-26-7-1-normalise-visitor-interest-t`,
`issue-27-7-2-in-memory-plan-store-reopena`,
`issue-28-7-3-budget-verdict-for-a-finishe` — all three cut from `main` at the
same commit `ffa0611`, which is also how we know they were one wave rather than
three runs written up as one.

**Three pull requests, each diff confined to its ticket's declared files.**
Six files added, and the set of changed files equals the set of declared files in
all three cases:

```
PR #31  <- #26   app/interests.py   tests/test_interests.py
PR #30  <- #27   app/store.py       tests/test_store.py
PR #32  <- #28   app/summary.py     tests/test_summary.py
```

**No file in two diffs.** Checked pairwise, not eyeballed.

**And the three trees compose.** Path disjointness is necessary and not
sufficient — two branches can touch different files and still be incompatible —
so the branches were merged into one tree locally. No conflict, and the suite goes
from **16 passed to 34 passed**. Each worker had run the full suite on its own
branch before opening its pull request; none of them had seen the other two.

Nobody merged anything: the pull requests are open and waiting for a human, which
is the one remaining gate.

## Isolation is structural, not policed

Worth asserting even though it should be impossible by construction, because
"should be impossible" is how the socket-proxy option looked before it was
tested. From `docker inspect` on all three:

- each worker's `/work` is **its own 384 MiB tmpfs** — no shared path exists to
  race on, and the size is under the 512 MiB memory cap because tmpfs pages are
  charged to the container's own cgroup
- **zero bind mounts**, on any of them
- read-only rootfs, `cap_drop: ALL`, `no-new-privileges`, unprivileged
- private IPC and PID namespaces — no worker can see another's processes
- memory and pid caps **non-zero** (an unset compose key inspects as `0`, meaning
  *no limit*, so the assertion is `> 0` rather than "a cap is set")
- `role=hermes-worker` and `managed-by=p1-dispatcher`, the labels that scope the
  spawn dispatcher's `stop` and `remove`
- attached to `hermes-isolated` only

None was OOM-killed. Three 512 MiB workers fit alongside the rest of the stack in
a 7.65 GiB Docker VM with room to spare; peak observed use per worker was ~16 MiB
resident before the model call and never approached the cap.

## The collision check, arbitrating

A check that never has to arbitrate is an argument, not evidence. Two things
close that, and they are different claims.

**On the live repository, mid-run.** Issue #29 was created deliberately declaring
`app/interests.py` — the file #26 had in flight. A read-only `plan` pass taken
while all three workers were alive:

```json
"concurrency": {"held": 3, "held_issues": [26, 27, 28], "limit": 3, "slots": 0},
"dispatch": [],
"skipped": [
  {"issue": 26, "reason": "already_claimed", "detail": "a worker holds this ticket"},
  {"issue": 27, "reason": "already_claimed", "detail": "a worker holds this ticket"},
  {"issue": 28, "reason": "already_claimed", "detail": "a worker holds this ticket"},
  {"issue": 22, "reason": "no_slots",       "detail": "concurrency limit 3 reached"},
  {"issue": 29, "reason": "file_conflict",  "detail": "#26 on app/interests.py"},
  {"issue":  2, "reason": "spec_issue",     "detail": "a specification to plan from, not work to do"}
]
```

The refusal names the ticket and the exact path, and it was decided against a
worker that genuinely held the file. #29 is now closed.

**On fixtures, reproducibly and without credentials.** `p6-fixtures/collision.json`
and `p6-fixtures/disjoint.json` are the same three tickets differing in **one
declared path**. With the path shared, exactly two of three dispatch and the
loser is refused `file_conflict`; change that one path and all three dispatch.
Keeping the two files near-identical rather than tidying them into one
parameterised fixture is the point: it pins the refusal to the shared path and
not to some other property of the ticket.

The refusal is also re-checked at `--limit 99`, because a concurrency cap would
have stopped the third ticket too, and that is a different property being
confused for this one.

## The harness is checked by breaking every claim in it

"No failures found" and "the detector is broken" produce identical output, so
every assertion above is worth exactly as much as this suite.
`./verify-parallel.sh mutate` runs **22 cases**. Each doctors a throwaway copy of
the evidence — or of `p4-dispatch-loop.py` — runs a *full* replay pass against
the copy, and requires a **named** check to go red. Requiring the specific check
matters: a mutation that turns the whole suite red proves the harness is brittle,
not that it discriminates.

| The lie | Caught by |
|---|---|
| a worker actually ran an hour later | `intervals intersect` |
| container windows widened to **forge** overlap | `witnesses describe the same event` |
| the `docker ps` sample only ever saw two | `docker ps sample` |
| one container missing from the record | `three distinct worker containers` |
| a worker exited non-zero | `exited 0` |
| a diff contains an undeclared file | `changed file is one its ticket declared` |
| two pull requests changed one file | `no file appears in two pull requests` |
| two workers pushed to one branch | `three distinct branches` |
| the branches came from different commits | `branch from one commit` |
| the three-way merge actually conflicted | `merge into one tree with no conflict` |
| bind mount / writable rootfs / host PID / no memory cap / no `/work` tmpfs / second network / missing `role` label | the seven isolation rules, one each |
| the live refusal was really the slot cap | `refused file_conflict` |
| nothing was in flight when it was recorded | `refused file_conflict` |
| `path_conflict` disabled in the dispatch loop | `collision fixture dispatched` |
| the evidence is gone entirely | the positive control |
| an evidence file is corrupt JSON | must FAIL, never crash into a pass |

The battery opens with its own positive control — an *unmutated* copy must pass
clean — because otherwise every "it went red" below could just mean the copy is
broken. **48 passed, 0 failed.**

Two real defects came out of writing it, which is the argument for writing it.
Three checks worded their failure differently from their claim, so they were
green for a reason nobody had read; every check now names the property
identically on both paths. And `live` mode re-queried `$TARGET_REPO` rather than
the repository the evidence records — `local.env` was repointed at a different
project within the hour, and the check would have gone on printing PASS while
verifying nothing. It reads the repo from the evidence now, and prints which one.

## What this does not prove

**Three is the tested width, not a demonstrated ceiling.** `P4_MAX_CONCURRENCY`
defaults to 3 and the memory budget in `docker-compose.yml` is written for three
workers. Nothing here says four would work, and the arithmetic has to be redone
before raising it — on a 7.65 GiB VM that was already ~4.5 GiB committed to other
containers.

**Model throughput under three concurrent workers was not re-measured here.** The
three finished in 84–135 s against 123–137 s for the two-worker run on 2026-08-12,
which suggests the third slot cost little — but they were different tickets of
different sizes, so that is an observation and not a measurement. The controlled
figures remain the ones in `MODEL-EVALUATION.md`: three 64K slots at 16.46 GiB,
aggregate throughput 1.77× at three concurrent, per-request 31.6 → 19.7 tok/s.

**A collision *between running workers* still cannot happen and still was not
tested,** because the dispatcher refuses to create one. What was tested is the
refusal. If the refusal were bypassed, the diff-scope gate in `worker.py` and the
dispatcher's validator would both catch the result afterwards — detection, not
prevention, and both after a container has already written the file.

**The dispatch was agentic, but only because the prompt named the skill.**
"Use your orchestrator-dispatch skill" is load-bearing: of four natural phrasings
measured on 2026-08-12, three failed — one made no tool call, one died on an
invalid `read_file` call, one claimed it had no network access and gave up. The
scheduling under test here is deterministic script; the unreliable component is
the routing in front of it, which is TECH-103's.

**Stale claims still have to be cleared by hand between runs** (TECH-102). This
run did not hit it because all three workers exited 0 on the first attempt. A run
where any of them fails will, and `--timeout 0` releases live claims as well as
dead ones, so it cannot be used while anything else is running.

**Nothing reports a plan that cannot parallelise.** The three tickets here were
written to be disjoint deliberately. A planner that chains everything, or that
declares broad directories, produces a plan that will never use more than one
worker and no output says so.

## Reproducing it

```bash
./verify-parallel.sh              # replay + fixtures, no credentials, no network
./verify-parallel.sh live         # + re-query the three pull requests
./verify-parallel.sh mutate       # + prove the harness can go red
```

To run it again from scratch, the preconditions are the interesting part:

1. Three open tickets whose `Files touched` lists are pairwise disjoint, whose
   `Blocked-by` sections are empty or closed, and whose dependencies the target
   README's `## Implementation constraints` section already sanctions. Two of
   three dying on `exit 10` measures nothing.
2. `OLLAMA_NUM_PARALLEL=3` in the environment the Ollama server actually
   **inherited** — check with `ps eww`, never `launchctl getenv`.
3. Enough room in the Docker VM for three 512 MiB workers on top of whatever else
   is running. `docker info` for the total; `docker stats --no-stream` for what is
   already spent.
4. No worker container left over under the name the next dispatch will want —
   `/spawn` returns `409 Conflict: name already in use`, and the names are
   `hermes-worker-<issue>`.

Then one prompt:

```bash
docker compose exec -T -u 10000 hermes \
  hermes -z "Dispatch the ready tickets in the target repository. Use your orchestrator-dispatch skill." \
  --skills orchestrator-planner,orchestrator-dispatch
```

Capture the timestamps *afterwards*, from the containers:

```bash
docker inspect --format '{{.Name}} {{.State.StartedAt}} {{.State.FinishedAt}} exit={{.State.ExitCode}}' \
  hermes-worker-26 hermes-worker-27 hermes-worker-28
```

## The captured run

Everything the harness replays is in `p6-evidence/`. It is raw output, not a
write-up, so that the write-up above can be checked against it.

| File | What it is |
|---|---|
| `01-plan-before.json` | the read-only schedule, before anything was dispatched |
| `02-docker-ps-poll.tsv` | `docker ps` sampled once a second through the whole run |
| `03-agent-dispatch.txt` | the one prompt, and what the agent reported |
| `04-plan-during-run.json` | a read-only pass taken mid-run: the live `file_conflict` refusal |
| `05-container-timestamps.txt` | `docker inspect` start/finish/exit for the three workers |
| `06-pull-requests.json` | the three pull requests, their branches, and their changed files |
| `07-three-way-merge.txt` | the three branches merged locally, and the suite on the result |
| `08-container-isolation.json` | mounts, namespaces, caps and labels per worker |
| `09-worker-logs.txt` | each worker's own log, end to end |

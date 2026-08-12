# The planner — decomposing a spec into dispatchable tickets

The planner is the first agent in the orchestration loop defined by
[ORCHESTRATOR.md](ORCHESTRATOR.md): it reads one issue labelled `spec`, decides
what the project is made of, and creates the implementation issues that a
dispatcher schedules and workers implement. It writes no application code.

Everything below is designed against one constraint, taken from
[MODEL-EVALUATION.md](MODEL-EVALUATION.md): the model is `gpt-oss:20b` at a
65,536-token window, roughly 23% of which is spent on tool definitions before any
work starts, generating at ~9 tok/s with a cold prefill measured at ~70 tok/s.

## What changed, and why

The first version of this planner was a **skill**: a seven-phase procedure the
model was asked to follow, one ticket per tool call. The scaffolding was right —
an append-only ledger, script-rendered issue bodies, per-row validation — but the
*control flow* lived in the model. Across four live runs it failed differently
every time:

- **It improvised instead of starting.** `git status`, greps for the project, a
  clone of the target repo, browser automation. None of it was in the procedure.
- **It misread its own environment.** `curl … | jq` exited 127 because `jq` is not
  installed; the model concluded network access was blocked. The network was fine.
- **It wrote the application it was supposed to be planning.** `pyproject.toml`,
  `app/__init__.py` and a test, into the agent's own data directory where they
  were useless to everyone. Removing the `write_file` tool did not stop it — it
  used `bash -c "cat > file"` instead.
- **It tried to verify code that did not exist.** Many turns spent on
  pip/uv/venv/pytest, for a project no worker had built yet.
- **It stopped after one ticket** and handed the human a numbered list to finish.
- **And, worst, it fabricated.** It printed a confident five-ticket plan — T1
  through T5, with goals, file lists and acceptance commands — when the ledger
  contained T1 and T2. Three tickets existed only in prose. Nothing but the
  mechanical validator caught it.

The pattern across every run is the same: **where the script owned control, the
output was flawless** — ticket rendering has never once produced a malformed
ticket — **and where the model owned control, it drifted**. The fourth failure is
the decisive one, because an agent that invents work to fill a gap is worse than
one that stops.

So control is inverted. `p3-plan.py plan` runs the loop itself and calls the model
only for decisions. The skill's job is now to start it and read its output.

## The shape

```
  p3-plan.py plan --repo owner/name --spec N

  [1/6]  init ledger; GET the spec issue and the target README     ── script
         └── plan/spec.md, plan/readme.md, plan/tickets.jsonl

  [2/6]  "given this spec and README, what files does the          ── MODEL
         finished project have?"                    ONE call, {"paths":[...]}
         └── validated, then appended as one ledger line

  [3/6]  while any layout path is unclaimed:                       ── script
           "given the layout, the tickets so far, and the          ── MODEL
            paths nobody owns yet, what is the NEXT ticket?"
                                                    ONE call, one ticket object
           └── validated, then appended as one ledger line

  [4/6]  p3-plan-lint.py --ledger    the whole graph, 18 checks    ── script
  [5/6]  emit: one issue per API call, linked under the spec       ── script
  [6/6]  p3-plan-lint.py --repo ...  what actually exists          ── script
```

The model is consulted in exactly two places, and both are a single decision with
everything needed to make it in the one prompt. It never sees a shell, never
writes a file, never chooses what to do next, and never decides when to stop.

## The model-call contract

Every call is the same four things:

**Small and single-purpose.** One layout, or one ticket. Not a plan. The ticket
prompt even says *"This is ticket T3. Describe only it. Do not describe the
tickets after it."* — the direct countermeasure to the five-tickets-in-prose
failure.

**Constrained to JSON, with the schema printed in the prompt.** The system message
is *"You are a planning function inside a script… you answer with exactly one JSON
object and nothing else"*, and the user message ends with the literal shape:

```
{"title": "<= 72 chars", "priority": 1, "files": ["<path from the layout>"],
 "blocked_by": ["T1"], "acceptance": "<one shell command>",
 "goal": "<one sentence on one line>", "details": "<40-80 words for the worker>"}
```

`response_format: {"type": "json_object"}` is sent as well, for endpoints that
honour it.

**Validated on receipt.** The reply is parsed, then run through exactly the same
rules `p3-plan.py add` applies to a human: one command in `acceptance` with no
shell operators and no prose, one priority in 1–4, a non-empty file list within
the recorded layout, no README, no path already claimed by a ticket this one is
not chained behind, `details` substantial enough to work from. A parse tolerance
exists for a ```json fence and a prose preamble — tolerating a fence is not
tolerating a fabrication, since the JSON is still the model's — but truncated or
absent JSON is a rejection.

**Stateless.** Nothing carries between calls except what the script puts in the
next prompt: the spec, the layout, the tickets already in the ledger, and the
paths nobody owns yet. A resumed run reconstructs all of it from the ledger, so a
fresh process is indistinguishable from a continuing one.

### When a reply is not usable

```
attempt 1 → rejected → the SAME conversation continues with:
             assistant: <the raw reply>
             user:      REJECTED: acceptance chains commands with '&&' …
                        Reply again with ONLY the JSON object described above.
attempt 2 → rejected → …
attempt N → rejected → STOP. exit 3.
```

and the stop prints:

```
error: the model did not produce a usable ticket T1 in 3 attempt(s).
Nothing was invented to fill the gap and no ticket was skipped; the plan stops
here so a human can see what the model actually said.
--- last raw reply ---
Of course! Here is the plan:

1. Set up the project
…
--- end of raw reply ---
```

There is no branch anywhere in the loop that supplies a value the model did not
send. The only three ways out of the ticket loop are: every layout path claimed
(exit 0), a budget or stall (exit 4), or an unusable reply (exit 3).

### Termination

Three independent guarantees, because one is a bug away from an infinite loop:

| Guarantee | Default | Fires when |
|---|---|---|
| coverage | — | every layout path is claimed by a ticket → **exit 0** |
| ticket budget | `--max-tickets 30` | more tickets than that, paths still unclaimed → **exit 4** |
| model-call budget | `--max-model-calls 80` | as above, counted in calls → **exit 4** |
| stall detector | `--max-stalls 3` | N consecutive tickets claim no *new* path → **exit 4** |

The stall detector exists because a ticket that claims nothing new can still be
perfectly valid — a wire-up ticket chained behind the owners of the files it
edits is exactly that. A model that only ever proposes those would otherwise spin
until the budget. Exit 4 names the paths nobody claimed; it never emits a partial
plan.

## What is unchanged, because it worked

**The model supplies fields; the script renders the format.** Section headings,
label sets and `Blocked-by: #N` lines are an f-string, not a generation, which
deletes the entire class of "malformed near the end" failures.

**The ledger is append-only, and one line is one ticket.** `tickets.jsonl` is
never rewritten. A crash, a context overflow or a 502 costs the ticket in flight
and nothing else. A torn *final* line — what a crash mid-append actually looks
like — is tolerated; a torn line anywhere else is corruption and an error.

**Validation happens at write time.** The bad row never enters the ledger, and in
the loop the rejection becomes the next prompt.

**The global reasoning happens on a 20-line artefact.** Cycles, overlap and
reachability are properties of the whole plan; by step 4 the plan is twenty short
lines and a script checks them, rather than a small model checking prose.

**Renderer and parser are separate implementations.** `p3-plan.py` renders the
body; `p3-plan-lint.py` parses it with its own parser, run as a separate process
so that separation is visible. Both are held against `ORCHESTRATOR.md` by
re-parsing the contract's own ticket template.

**Local ids until emit.** Asking a model to predict issue numbers is asking it to
be wrong.

**`status:backlog` only.** Two status labels at once is ambiguous state, and
approval is a human act.

### One new thing: provenance

Every ticket record carries `raw_sha256`, the SHA-256 of the exact model reply it
was built from, and every call — accepted or rejected — is appended to the ledger
as a `modelcall` row with the same hash, the attempt number and the rejection
reason. That turns "the planner does not fabricate" from an assertion into
something a harness can check: re-derive each ticket's seven fields from the
replies the model actually sent, and compare. See the anti-fabrication suite
below.

## The validator

`p3-plan-lint.py` parses tickets the way the dispatcher will and exits non-zero
if the plan is not dispatchable. It runs in three modes over one check engine:
`--ledger` (before creation), `--fixtures` (rendered bodies, offline, no token)
and `--repo/--parent` (live). A check that cannot be evaluated in a mode reports
SKIP, never a silent PASS.

| Check | Fails when |
|---|---|
| `FMT-SECTIONS` | a section is missing, duplicated, out of order, or invented |
| `FMT-TITLE` | the title is empty or over 72 characters |
| `FMT-GOAL` | Goal is empty or spans more than one line |
| `FMT-FILES` | no files, an absolute path, a duplicate, an unparseable line |
| `FMT-DETAILS` | Details is too thin to work from |
| `FMT-ACCEPT` | prose, multi-line, or more than one command |
| `FMT-BLOCKED` | `none`, prose, a self-reference, or an empty section |
| `LBL-PRIORITY` | zero or two priority labels |
| `LBL-BACKLOG` | `status:backlog` missing |
| `LBL-STATUS` | the planner approved its own ticket, or claimed blocked with no blockers |
| `LBL-NOSPEC` | a child carries `spec` and would be re-planned |
| `DEP-RESOLVE` | `Blocked-by` points at an issue not in the plan |
| `DEP-CYCLE` | the dependency graph has a cycle |
| `DEP-ROOT` | nothing is dispatchable on day one |
| `CONC-FILES` | two tickets that may run together share a file |
| `SAFE-README` | a ticket edits the target README or `.git` |
| `SIZE-FILES` | a ticket touches more files than one concern should |
| `LINK-PARENT` | a ticket is not a sub-issue of the spec |

Two are worth spelling out.

**`CONC-FILES` compares every unordered pair, not dependency levels.** Two tickets
can run at the same time unless one transitively blocks the other — which is *not*
the same as being in different levels of the graph. If A blocks B and C is
independent, B and C are concurrent despite sitting at different depths.

**`FMT-ACCEPT` tokenises with `shlex` and rejects shell operators as tokens.** So
`python -c "import x; print(1)"` is legal — the `;` is inside a quoted argument —
while `cd src && pytest` is not. `cd foo && pytest` is a real cost of this rule,
and the documented remedy is for the ticket to commit a make target instead.

## Verifying it

`./verify-planner.sh` — **101 checks, 0 failures**, no credentials, no live model,
no GitHub. The only socket it opens is a loopback mock endpoint.

The pre-existing suites still run: contract agreement against `ORCHESTRATOR.md`,
eighteen positive controls that each trip one specific check, a coverage assertion
that refuses a clean sweep unless every check has been *made* to fail, a
renderer-vs-parser round trip, and seven `add` calls that must be refused at
entry. On top of those, five suites now drive the **loop** against canned replies
from `p3-fixtures/model/replies.json` — twenty scenarios, and the harness fails
if any of them goes unused.

**A well-formed reply produces a conforming ticket.**

```
  PASS  a well-formed model reply drives the loop to completion (exit 0)
  PASS  the loop produced 4 tickets from the mock's replies
  PASS  every ticket the loop produced satisfies the contract validator
  PASS  the run wrote nothing outside its plan directory (the model has no shell)
  PASS  a fenced reply with a preamble is accepted (the JSON is still the model's)
```

**A malformed reply is retried, and exhausting the retries fails loudly.** Three
scenarios: prose instead of JSON, JSON truncated mid-object (what a token budget
running out actually looks like), and a JSON *array of five tickets* — the
original fabrication failure, in machine-readable form.

```
  PASS  bad-json: the loop stopped loudly (exit 3) instead of continuing
  PASS  bad-json: the raw reply is printed, so a human can see what was actually said
  PASS  bad-json: no ticket was invented to fill the gap (ledger holds 0)
  PASS  bad-json: nothing was emitted
  PASS  json-array: the loop stopped loudly (exit 3) instead of continuing
  PASS  the rejected decision was retried to the configured limit (3 attempts)
  PASS  the retry prompt carries the previous reply and the rejection reason
  PASS  a rejected first attempt followed by a correct one recovers (exit 0)
```

The last two matter together: the retry has to actually feed the error back, and
it has to be *capable* of succeeding, or "retry" is theatre.

**Schema violations are rejected, and for the right reason.** Ten scenarios, each
one well-formed JSON with exactly one defect, run with `--retries 0` so the first
reply decides. Requiring the *specific* rejection message rules out a planner that
simply rejects everything.

```
  PASS  schema-missing-files -> rejected: missing key 'files'; the reply must carry all of …
  PASS  schema-two-priorities -> rejected: priority must be 1, 2, 3 or 4 (a number, not a list)
  PASS  schema-prose-acceptance -> rejected: acceptance reads as prose, not a command
  PASS  schema-off-layout -> rejected: src/example/utils.py is not in the recorded file layout
  PASS  schema-touches-readme -> rejected: tickets may not touch the target README
  … and empty-files, chained-acceptance, long-title, thin-details, unknown-blocker
```

**The loop terminates, three ways.**

```
  PASS  the loop stopped because all 7 layout paths were claimed by 4 tickets
  PASS  hitting the ticket budget with paths unclaimed fails (exit 4)
  PASS  the budget failure names the paths no ticket claimed
  PASS  a plan that hit the budget emitted nothing
  PASS  a non-converging model is stopped by the stall detector (exit 4)
  PASS  the stall was caught after 3 tickets, not after the 25-ticket budget
```

**The ledger holds only what the model returned.** This is the property the
redesign exists for, so it is checked mechanically rather than argued. Each
ticket's `raw_sha256` is looked up in the log of replies the mock actually sent,
the seven judgement fields are re-derived from that reply, and compared field for
field. Then a plausible ticket that no reply ever contained is appended to a copy
of the ledger, to prove the check can fail:

```
  PASS  all 4 ledger tickets re-derive, field for field, from replies the model actually sent
  PASS  a fabricated ticket IS caught by that check (so the check can fail)
  PASS  one accepted model reply per ticket in the ledger (4 = 4)
```

**An interrupted run resumes.** The mock endpoint starts returning HTTP 500 after
two tickets; the run dies; the scenario is switched back and the *same command* is
run again.

```
  PASS  the two tickets decided before the failure survived in the ledger
  PASS  the resumed run said it was resuming rather than starting over
  PASS  the layout was not re-asked - one layout call per plan, ever
  PASS  no ticket id appears twice after resuming (4 tickets)
  PASS  the tickets decided before the interruption were not re-decided
  PASS  the resumed plan reaches the same size as an uninterrupted one (4)
```

**And a positive control for the mock suites themselves.** A scenario in which no
reply is ever usable must make the run fail; if it did not, everything above would
be passing vacuously.

```
  PASS  a model that never answers usefully produces a FAILED run (exit 3)
  PASS  ...and an empty ledger, not a plausible-looking plan
  PASS  every one of the 20 canned scenarios was actually exercised
```

## Measured: how often one planning call is schema-valid first try

This is the tool-calling reliability figure the project owed, measured on the
actual workload rather than on a benchmark. `p3-plan.py measure` issues N
**independent single-shot** calls — a fresh conversation each time, `--retries 0`,
so nothing is rescued by a second attempt — against a fixed scenario in
`p3-fixtures/spec/`, and classifies each outcome.

```bash
python3 p3-plan.py measure --calls 20 --kind both \
  --spec-file p3-fixtures/spec/spec.md --readme-file p3-fixtures/spec/readme.md \
  --seed p3-fixtures/spec/seed.json
```

`gpt-oss:20b-64k`, temperature 0.2, `max_tokens` 2048, `response_format:
json_object`, served by Ollama at a 65,536-token window:

| Decision | First-try schema-valid | Median latency |
|---|---|---|
| layout (`{"paths": [...]}`) | **19/20 — 95.0%** | 23.0 s |
| next ticket (7 fields) | **20/20 — 100.0%** | 28.6 s |
| **combined** | **39/40 — 97.5%** | — |

**The one failure was not a malformed reply.** It was an *empty* one: the model
spent all 2048 generation tokens reasoning and returned `content: ""` with 8,987
characters in `reasoning`. That is a distinct failure mode from bad JSON — there
is nothing to feed back, because nothing was said — so it is reported separately
by `measure` and raised as `EmptyReply` rather than lumped in with transport
errors. The remedy is a larger `P3_MODEL_MAX_TOKENS`; the measurement is what
found it, which is the point of measuring the real workload.

**No reply was ever schema-*invalid*.** Across 40 single-shot calls, zero produced
JSON that parsed but violated the ticket or layout schema. Three end-to-end runs
of the full loop agree: 14 model calls, 0 rejections, 0 retries.

That is a better result than this design assumed, and it is worth being precise
about why it does not make the scaffolding redundant:

- The measurement is of a **small, single-purpose, schema-stated** call. It says
  nothing about the same model asked to follow a seven-phase procedure, which is
  what actually failed four times. The reliability is a property of the question,
  not only of the model.
- 97.5% per call compounds. A twenty-ticket plan is twenty-one calls; at 97.5%
  each, the chance of no failure anywhere is about 59%. Retries and a loud stop
  are what make that survivable.
- Schema-valid is not correct. See the next section: every ticket in the first
  live run was schema-valid, and one of them could never have passed.

### What three live end-to-end runs actually produced

The loop was run three times against the live model with the fixture spec and
`--dry-run` emit. All three exited 0 with a plan that passed all 18 validator
checks. Two real defects showed up anyway, and both are worth recording because
they are what "schema-valid but wrong" looks like:

**Run 1 — an acceptance command that could never pass.** The foundation ticket
created `pyproject.toml` and `src/example/__init__.py`, and gave as its acceptance
`pytest tests/test_app.py` — a file a *different* ticket creates. One command, no
shell operators, no prose: `FMT-ACCEPT` had nothing to object to. This is now
rejected at proposal time, generically: if the acceptance command names a path in
the layout that neither this ticket nor any ticket it is blocked by creates, the
reply is rejected and the reason is fed back. `schema-foreign-acceptance` in the
harness is that case.

**Runs 1 and 2 — the foundation planned last, and unblocked.** In both, the
dependency manifest landed in the final ticket with no `Blocked-by`, while the
feature tickets were also unblocked. `DEP-ROOT`, `DEP-CYCLE` and `CONC-FILES` all
passed — the graph was perfectly consistent — and wave 1 would have dispatched a
worker to run `pytest` against a project that did not install yet. A missing
dependency is invisible to a consistency check.

The old skill said *"T1 creates the dependency manifest… every other ticket is
blocked by it"*, in prose the model was supposed to follow. Under the new design
the prompt is the only channel, so that rule now appears in the ticket prompt
itself, stated in both directions: the first ticket is told it is the foundation,
and every later ticket is told which ticket id it must be blocked by. Run 3, with
that rule present, produced `wave 1: T1` alone and both later tickets transitively
blocked by it — on the first try, with no rejections.

It is a fair criticism that this was found by reading the output rather than by a
check. It is also the honest sequence: the loop made the mistake reproducible and
cheap to see, one of the two mistakes turned out to be mechanically checkable, and
the other turned out to be fixable in the prompt because the prompt is now a
single small thing rather than a procedure.

## Where this will still get it wrong

Stated plainly, because the checks above prove tickets *parse*, not that they are
*good*, and the gap between those is where this will actually fail.

**Ticket sizing is the weakest judgement and the least checkable, and this is
confirmed rather than predicted.** `SIZE-FILES` counts files. The three live runs
produced five, three and three tickets for layouts of ten, seven and eight paths —
consistently coarse. Run 3's last ticket bundled the record store *and* the
application assembly into one, and its first ticket was titled "Set up package and
test environment", which is close to the "never write a ticket called *set up the
project*" anti-pattern even though it did name concrete files. Run 3 also put
`tests/test_store.py` in the foundation ticket and `src/example/store.py` in a
later one, splitting a module from its own test — the opposite of the rule that
tests belong to the ticket that creates the code. Every one of those passed all 18
checks. **A human reading five titles catches this in a minute; no check does.**

**Acceptance commands are plausible and only partly checked.** The planner now
rejects an acceptance command that runs a layout file the ticket does not create
and is not blocked behind (see the live-run notes above). It still cannot confirm
that a command *fails before* the work and *passes after* — the property that makes
it an acceptance criterion at all — and it says nothing about a command naming a
path that is in no ticket and no layout. The real fix is not in the planner: the
dispatcher should run the acceptance command on the base branch and require it to
**fail** before dispatching. That "red before green" gate is not built yet.

**Missing dependencies are invisible, and the model does omit them.** The graph is
proven consistent, not correct. Two of three live runs left the foundation ticket
unblocked *and* left every feature ticket unblocked, so wave 1 would have run
`pytest` in a project with no manifest. Adding the rule to the prompt fixed those
three runs; three runs is not evidence that it always will. If B needs what A
creates and simply does not say so, every check still passes and the failure
appears at runtime as a worker that cannot build.

**And the model will invent dependencies the README forbids.** Run 1's assembly
ticket proposed "Create a FastAPI app" for a README that sanctions pytest and
nothing else and explicitly says the router opens no socket. `ORCHESTRATOR.md`
prohibits adding an unsanctioned dependency, but that prohibition is enforced on
the *worker*, not on the planner, and there is still no check here for it —
detecting it would mean deciding which names in a Details paragraph are packages.

What changed with TECH-101 is that the planner is at least **told** the list.
Both the layout call and every ticket call now carry the spec's
`## Implementation constraints` section verbatim, as an explicit "a worker
refuses anything else", and where the spec sanctions nothing they say to plan
against the standard library. That converts the failure from *invisible* to
*discouraged*; it does not make it *impossible*, and a ticket that presupposes an
unsanctioned package will still pass every mechanical check here and be refused
at the worker. The gap is real and is the honest state of it.

**File-layout quality is the ceiling on everything downstream, and it is now a
single point of failure.** One call decides the layout; every ticket is
constrained to it, and a ticket may not name a path outside it. That kills path
drift, which was a real failure, and buys it with rigidity: a bad layout cannot be
recovered from inside the loop, only by discarding the plan directory and
starting again. Exit 4 is what that looks like.

**Coverage is the stop condition, so a wire-up ticket may never be requested.**
The loop stops the moment every layout path is claimed. If the model folds
assembly into an earlier ticket, fine; if the project genuinely needed a separate
late ticket that only *edits* files others own, the loop will never ask for it,
because such a ticket claims no new path. This is a deliberate trade — the
alternative stop condition is a model deciding when it is finished, which is one
of the failures being designed out — but it is a real limitation.

**Details prose will be thin.** `FMT-DETAILS` counts characters, which a model
satisfies by restating the title at length.

**And it is slow.** Every ticket is a call, and a call to a 20B model at ~9 tok/s
takes tens of seconds. A twenty-ticket plan is measured in tens of minutes, before
any retries. That is the price of the property that a failure costs one decision.

## What has still not been tested

- **No live GitHub run.** No credentials were available, so issue creation and
  sub-issue linkage are exercised only through `--dry-run` fixtures. The REST
  calls are written against the documented API — including the detail that
  `POST /issues/{n}/sub_issues` wants the issue's *database id*, not its number —
  but they have not been proved against the service.
- **The dispatcher's parser is not cross-checked.** The validator agrees with
  `ORCHESTRATOR.md`; whether the dispatch loop agrees with both is a test that
  belongs with the dispatcher.
- **No end-to-end run against a real target repository.** The loop has been run
  end to end against the live model three times, but with the spec and README
  supplied from `p3-fixtures/spec/` and with `--dry-run` emit. A real target
  repository would exercise `spec-show`, real issue creation and sub-issue
  linkage, none of which the fixture path touches.
- **Three runs is not a sample.** The 97.5% first-try figure comes from 40 calls
  on one scenario with one model at one temperature. It does not generalise to a
  larger README, to a project the model has less prior exposure to, or to the
  point where the prompt starts carrying fifteen already-planned tickets — the
  ticket prompt grows with the plan, and nothing here has been measured at that
  size.

## Files

| File | Purpose |
|---|---|
| `hermes-skills/autonomous-ai-agents/orchestrator-planner/SKILL.md` | The planner skill: now one command, plus how to read its output |
| `.../references/worked-example.md` | Five tickets and the layout they build |
| `.../scripts/p3-plan.py` | The loop, the model client, the ledger, the renderer, the emitter (stdlib only) |
| `.../scripts/p3-plan-lint.py` | The validator: 18 checks, three input modes |
| `verify-planner.sh` | Harness: contract agreement, positive controls, coverage, round-trip, and the mock-model suites |
| `p3-fixtures/good/` | A conforming five-ticket plan, as rendered issues |
| `p3-fixtures/spec/` | A spec issue, a README and a seed scenario — planning *input*, offline |
| `p3-fixtures/model/replies.json` | Twenty canned model replies the harness drives the loop with |
| `bootstrap-labels.sh` | Creates the labels the emitter requires |

Install the skill by copying the `orchestrator-planner` directory into the
agent's data directory under `skills/autonomous-ai-agents/`; the data directory's
location is machine-specific and lives in `local.env`.

## A note on the environment

The scripts are stdlib Python. GitHub is reached over the REST API through
`urllib`, which honours `HTTPS_PROXY` and therefore works through the egress
allowlist in [EGRESS.md](EGRESS.md) — the agent container was measured to have
`python3` 3.13, `curl` and `git`, and **no `gh` CLI** and **no `jq`**, so a
planner built on either would not run at all.

The inference call deliberately does *not* use that proxy. The model gate is an
internal host on the isolated network; routing inference through the domain
allowlist would be denied, and a denial there is indistinguishable from "the model
is down" — which is exactly the misdiagnosis one of the four failed runs made.

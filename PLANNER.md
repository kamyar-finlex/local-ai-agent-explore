# The planner — decomposing a spec into dispatchable tickets

The planner is the first agent in the orchestration loop defined by
[ORCHESTRATOR.md](ORCHESTRATOR.md): it reads one issue labelled `spec`, decides
what the project is made of, and creates the implementation issues that a
dispatcher schedules and workers implement. It writes no application code.

Everything below is designed against one constraint, taken from
[MODEL-EVALUATION.md](MODEL-EVALUATION.md): the model is `gpt-oss:20b` at a
65,536-token window, roughly 23% of which is spent on tool definitions before any
work starts, generating at ~9 tok/s with a cold prefill measured at ~70 tok/s.

## The problem this design is about

The naive planner is one prompt: *here is the spec, output twenty issues.* It
fails three ways at once, and all three are consequences of the model rather than
the prompt:

- **Long outputs degrade.** Ticket 3 is well-formed, ticket 17 is missing a
  section. There is no wording that fixes this.
- **A failure costs everything.** A timeout at ticket 17 loses tickets 1–16 too,
  because they existed only in the completion.
- **The window is finite.** Twenty issue bodies plus the spec plus the reasoning
  does not fit in ~50K tokens, and what does not fit gets silently truncated.

So the design question is not "what is the best prompt" but "what is the smallest
unit of work a failure can cost". Here it is one ticket.

## The shape

```
  spec issue  ──▶  plan/spec.md      read once, kept on disk, never restated
                   plan/readme.md

  step 3      ──▶  layout            every file the finished project has,
                                     recorded before any ticket exists

  step 4      ──▶  tickets.jsonl     ONE `add` call per ticket, append-only.
                   ├─ T1                 validated at the moment it is written
                   ├─ T2                 ~40 output tokens per turn
                   └─ ...

  step 5      ──▶  p3-plan-lint.py --ledger      the whole graph, checked while
                                                 it is still 20 short lines

  step 6      ──▶  emit --all        one issue per API call; the ledger records
                                     each number as it is assigned

  step 7      ──▶  p3-plan-lint.py --repo ...    what actually exists in GitHub
```

Nothing in that pipeline requires the model to hold more than one ticket at a
time, and nothing is ever rewritten.

## Seven decisions, and why

**1. The model supplies fields; the script renders the format.** `p3-plan.py add`
takes `--title --priority --files --acceptance --goal --details --blocked-by` and
`p3-plan.py emit` renders the contract's markdown from them. Section headings,
label sets and `Blocked-by: #N` lines are a f-string, not a generation, which
deletes the entire class of "malformed near the end" failures. What is left for
the model is the part only it can do: deciding what the tickets *are*.

**2. The ledger is append-only, and one line is one ticket.** `tickets.jsonl` is
never rewritten — `add` appends, `emit` appends the assigned issue number. State
is rebuilt by replay. A crash, a context overflow or an API error costs the
ticket in flight and nothing else; the next run reads the ledger, sees what
exists, and continues. `verify-planner.sh` proves this by appending a synthetic
"already created" record and asserting the emitter skips it. A torn final line —
what a crash mid-append actually looks like — is tolerated; a torn line anywhere
else is an error, because that would be corruption rather than interruption.

**3. Validation happens at write time, not at review time.** `add` rejects a
prose acceptance criterion, a file another concurrent ticket already claimed, an
unknown blocker, a README edit. The model is corrected in the turn where it still
remembers what it meant, and the bad row never enters the ledger. Feedback three
minutes later, after twenty more tickets, is feedback the model cannot act on.

**4. The global reasoning happens on a 20-line artefact.** Dependency order and
file disjointness are properties of the whole plan, and a small model cannot hold
twenty issue bodies while reasoning about them. It does not have to: by step 5
the plan is twenty short lines, and the checks that matter — cycles, overlap,
reachability — are run by a script over that, not by the model over prose.

**5. Renderer and parser are separate implementations.** `p3-plan.py` renders the
body; `p3-plan-lint.py` parses it with its own parser. If both were one function,
the round-trip test would prove only that the code agrees with itself. They are
held against each other in the harness, and both are held against
`ORCHESTRATOR.md` by re-parsing the contract's own ticket template.

**6. Local ids until emit.** Issue numbers do not exist while planning, so
tickets refer to each other as `T1`, `T2`, and the emitter substitutes real `#N`
at creation time — refusing to emit a ticket whose blocker has no number yet.
Asking a model to predict issue numbers is asking it to be wrong.

**7. `status:backlog` only, never `status:blocked`.** The contract permits the
planner to set `status:blocked`, but a backlog ticket is not dispatchable for a
reason that has nothing to do with its blockers, and two status labels at once is
ambiguous state. The emitter stamps `status:backlog` plus exactly one priority;
`LBL-STATUS` still allows `status:blocked` where a `Blocked-by` section exists,
so the dispatcher may add it after approval.

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

Two of these are worth spelling out.

**`CONC-FILES` compares every unordered pair, not dependency levels.** Two
tickets can run at the same time unless one transitively blocks the other — which
is *not* the same as being in different levels of the graph. If A blocks B, and C
is independent, then B and C are concurrent despite sitting at different depths.
Checking levels would have missed exactly that case, which is the common one.

**`FMT-ACCEPT` tokenises with `shlex` and rejects shell operators as tokens.**
That way `python -c "import x; print(1)"` is legal — the `;` is inside a quoted
argument — while `cd src && pytest` is not. The dispatcher runs one command and
reads one exit code; `cd foo && pytest` is a real cost of this rule, and the
documented remedy is for the ticket to commit a make target instead.

## Verifying the validator

`./verify-planner.sh` — **45 checks, 0 failures**, no credentials, no network.

The interesting suites are not the ones that confirm a good plan passes:

- **Contract agreement.** `ORCHESTRATOR.md` is re-parsed at verification time and
  its ticket template, status labels and priority range are compared with the
  validator's constants. The contract's own preamble warns that a planner writing
  `Blocked-by` against a dispatcher reading `Blocks` fails silently; this is the
  guard for the same failure one layer up. Editing the contract's format without
  editing the validator turns this suite red.
- **Positive controls.** Eighteen copies of a conforming plan, each with exactly
  one deliberate defect. Each must be rejected *and* must fire the specific check
  it was built to trip — "exit non-zero" alone would be satisfied by a validator
  that rejects everything.
- **Coverage of the checks themselves.** The union of checks fired across those
  controls must cover the entire check list. A check nothing has ever fired is
  indistinguishable from a check that cannot fire; this repo has already shipped
  one probe that could never fail ([RESULTS.md §7](RESULTS.md)), and this suite
  is the direct consequence of that.
- **Round-trip.** A plan built through `add`, emitted with `--dry-run`, and fed
  back to the validator — renderer against parser, both independent.
- **Early rejection.** Seven malformed `add` calls that must be refused at entry,
  followed by an assertion that the ledger still holds only the valid row.

What the malformed plans caught, in the harness's own words:

```
  PASS  chained-acceptance -> FMT-ACCEPT
  PASS  file-overlap -> CONC-FILES
  PASS  dependency-cycle -> DEP-CYCLE,DEP-ROOT
  PASS  self-approved -> LBL-STATUS
  PASS  orphan-ticket -> LINK-PARENT
```

`dependency-cycle` is the honest one: a plan where everything is blocked is
necessarily cyclic, so `DEP-ROOT` cannot be tripped independently of `DEP-CYCLE`
in an acyclic graph. It is recorded as covered by that control rather than given
a control that pretends to be independent.

## Where a 20B model will get this wrong

Stated plainly, because the checks above prove that tickets *parse*, not that
they are *good*, and the gap between those is where this will actually fail.

**Ticket sizing is the weakest judgement, and the least checkable.** `SIZE-FILES`
counts files. A ticket listing one source file and one test, with a Goal of
"implement the API", passes every check in the table and is unworkable. Expect
the model to under-split — a fifteen-ticket plan where four tickets are secretly
half the project — and expect that to surface only when a worker fails. Nothing
here catches it; a human reading the titles does.

**Acceptance commands will be plausible and untested.** The validator confirms a
command is a single command. It cannot confirm that it fails before the work and
passes after — the property that makes it an acceptance criterion at all. A model
will happily write `pytest -q tests/test_store.py` for a ticket that never
creates that file. The real fix is not in the planner: the dispatcher should run
the acceptance command on the base branch and require it to **fail** before
dispatching. That "red before green" gate is not built yet.

**Missing dependencies are invisible.** The graph is proven consistent, not
correct. If B needs what A creates and simply does not say so, every check passes
and the failure appears at runtime as a worker that cannot build. Detecting that
requires understanding the code that does not exist yet.

**File-layout quality is the ceiling on everything downstream.** A good layout
makes tickets naturally disjoint; a bad one forces long `Blocked-by` chains and
serialises the plan. A small model produces a serviceable layout for a
five-to-ten file project and something mushy above that — a `utils.py` that every
ticket wants to edit, or a single `app.py` holding four concerns. The skill bans
both by name, which helps and does not solve it.

**Details prose will be thin.** `FMT-DETAILS` counts characters, which a model
satisfies by restating the title at length. The instruction to reference README
sections rather than restate them is the kind of guidance a 20B model follows
about half the time.

**Nested quoting will break.** `--acceptance "python -c \"import example\""`
survived here, but shell quoting inside a tool call is a reliable way to make a
small model produce a malformed command. Prefer acceptance commands with no
nested quotes; `add` refuses what does not tokenise, so the failure is at least
loud.

**It will try to batch.** Under any pressure to be efficient, a model chains
several `add` calls into one `terminal` invocation, which is precisely the
long-output failure the design avoids. The per-call validation limits the damage:
the first refusal aborts the rest.

**And it will be slow.** Twenty tickets is twenty-plus turns. At ~9 tok/s
generation, with cold prefill dominating whenever the slot is shared, a full
planning run is measured in hours, not minutes. That is the price of the trade
made here — wall-clock time for the property that a failure costs one ticket.

## What was not tested

- **No live GitHub run.** No credentials were available, so issue creation and
  sub-issue linkage are exercised only through `--dry-run` fixtures. The REST
  calls are written against the documented API — including the detail that
  `POST /issues/{n}/sub_issues` wants the issue's *database id*, not its number —
  but they have not been proved against the service.
- **No live model run.** The skill has not been executed by `gpt-oss:20b` end to
  end; the failure modes above are predictions from the model evaluation, not
  observations. The next useful experiment is one real run against a throwaway
  repository, comparing what the model produced with what the validator says.
- **The dispatcher's parser is not cross-checked.** The validator agrees with
  `ORCHESTRATOR.md`; whether the eventual dispatch loop agrees with both is a
  test that belongs with the dispatcher.

## Files

| File | Purpose |
|---|---|
| `hermes-skills/autonomous-ai-agents/orchestrator-planner/SKILL.md` | The planner skill: procedure, judgement calls, prohibitions |
| `.../references/worked-example.md` | Five tickets and the layout they build |
| `.../scripts/p3-plan.py` | Ledger, contract renderer, issue emitter (stdlib only) |
| `.../scripts/p3-plan-lint.py` | The validator: 18 checks, three input modes |
| `verify-planner.sh` | Harness: contract agreement, positive controls, coverage, round-trip |
| `p3-fixtures/good/` | A conforming five-ticket plan, as rendered issues |
| `bootstrap-labels.sh` | Creates the labels the emitter requires |

Install the skill by copying the `orchestrator-planner` directory into the
agent's data directory under `skills/autonomous-ai-agents/`; the data directory's
location is machine-specific and lives in `local.env`.

## A note on the environment

The scripts are stdlib Python and speak the GitHub REST API through `urllib`,
which honours `HTTPS_PROXY` and therefore works through the egress allowlist in
[EGRESS.md](EGRESS.md). That is not a preference: the agent container was
measured to have `python3` 3.13, `curl` and `git`, and **no `gh` CLI**, so a
planner built on `gh` would not run at all.

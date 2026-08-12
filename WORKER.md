# The worker — turning one ticket into one pull request

The worker is the last agent in the loop defined by
[ORCHESTRATOR.md](ORCHESTRATOR.md). It is handed exactly one issue number,
implements it on its own branch, runs the ticket's acceptance command and the
project's full test suite, and opens a pull request. It knows the target
project's README and its own issue, and nothing else: no other ticket, no other
worker's branch, no plan.

It is `worker.py`, and it is **a script that calls a model**, not a model that
runs a script. That sentence is the whole design.

## What it is designed against

Same constraint as the planner, from [MODEL-EVALUATION.md](MODEL-EVALUATION.md):
`gpt-oss:20b` at a 65,536-token window, ~9 tok/s generation, three parallel slots
on the gate. And the same lesson as [PLANNER.md](PLANNER.md), which was paid for
four times over: a small model asked to *follow a procedure* improvises,
misdiagnoses its own tooling, writes files it was told not to, routes around a
tool that is taken away from it, stops early, and — worst — fabricates work that
does not exist. A small model asked **one narrow question** answers it correctly
97.5% of the time on the first try.

The worker is therefore shaped so that the model is asked one narrow question and
never anything else. It never chooses what to do next. It never runs a command.
It never decides when the work is done. It cannot even choose which file it is
writing: the script asks about one path and refuses a reply about any other.

## The shape

```
worker.py                                   (exit code in brackets)
  |
  1. config: GITHUB_TOKEN, TARGET_REPO, P4_ISSUE, model endpoint  [2 if missing]
  |
  2. GET the issue  ->  parse against ORCHESTRATOR.md's ticket format
  |        malformed?  comment a p4-defect and stop                [4]
  |        (before the clone. before the first model call.)
  |
  3. git clone --depth 1 ; git checkout -b issue-<N>-<slug>        [8 on failure]
  |
  4. for each path in Files touched:            <-- THE ONLY MODEL CALLS
  |        ask for the complete contents of THAT path
  |        validate: right path, one file, non-empty, no test weakened,
  |                  no unsanctioned dependency
  |        reject -> retry with the rejection fed back -> stop      [3 / 10 / 11]
  |        "needs_file"  -> comment, write nothing, stop            [5]
  |     (nothing is written to disk during this loop)
  |
  5. write all the declared files
  |
  6. repeat up to P5_ATTEMPTS times:
  |        run the acceptance command, exactly as the ticket states it
  |        pass -> break
  |        fail -> the SCRIPT picks one file, feeds the failure back,
  |                re-asks that file, rewrites it
  |     still failing -> comment, commit nothing                    [6]
  |
  7. run the project's full test suite
  |        fail -> comment, commit nothing                          [7]
  |
  8. scope gate: git status shows nothing outside Files touched      [9]
  |
  9. git add <declared> ; check the staged diff is a subset again    [9]
  |  git commit ; git push (no force, explicit refspec)             [8]
  |  POST /pulls with "Closes #N"                                   [8]
  |  final comment on the issue                                     [0]
```

Every step in that list is executed by the script. The model appears at exactly
one place — step 4, and its re-entry from step 6 — and what it returns is a file's
contents. Nothing else.

## The model-call contract

One system message, one user message, one JSON object back. Stateless: each call
is built from the ticket and the checkout, never from the previous reply's
conversation.

The prompt is reproduced in full in
[p4-worker-instructions.md](p4-worker-instructions.md). It carries the goal, the
details, the acceptance command, the README, every declared path, the current
contents of the file being asked about, and the current contents of the other
declared files — because a test file that does not match the module it tests is
the most common way a per-file loop produces something that cannot pass.

Two reply shapes are accepted, both entirely the model's:

```json
{"path": "src/thing.py", "contents": "the complete file text"}
{"needs_file": "src/__init__.py", "reason": "one line"}
```

### When a reply is not usable

The same discipline as the planner: validate on receipt, retry with the parse or
schema error fed back, then **stop loudly** and print the raw reply. There is no
path that returns contents the model did not send, and none that writes a path
the model was not asked about.

| Rejected because | Fed back as | If it never recovers |
|---|---|---|
| not JSON / truncated | the parse error | exit 3, raw reply printed |
| `path` is a different file | "this call is about `X`" | exit 3 |
| carries `files` / `extra_files` | "one file per reply" | exit 3 |
| `contents` empty, huge, or NUL-bearing | the limit it broke | exit 3 |
| a test function disappeared, or a `skip`/`xfail` appeared | which test | exit 11 |
| a manifest gained a package the README never mentions | which package | exit 10 |
| the endpoint is down or answered empty | nothing to feed back; backoff | exit 3 |

Exits 10 and 11 are separate from 3 on purpose. "The model cannot produce valid
JSON" and "the model tried to delete a test to go green" are different findings,
and collapsing them would hide the interesting one.

## Out-of-scope writes, in three layers

`ORCHESTRATOR.md` says a worker changes only the files under `Files touched`, and
that list is the entire reason the ticket could be started beside others. Three
independent layers hold it, because each catches something the others cannot:

1. **The reply validator.** A reply whose `path` is not the requested path is
   refused. A reply carrying an `extra_files` map is refused. This catches the
   model *naming* another file.
2. **The writer.** `write_files()` re-checks every path against the declared set
   and refuses to write anything else, so a future refactor cannot widen it by
   accident. It also refuses a path that escapes the checkout.
3. **The git scope gate.** Before anything is committed, `git status --porcelain
   -uall` must show no change outside the declared list, and after staging, the
   staged diff must be a subset of it. This is the only layer that can catch a
   file created by *running the acceptance command* — the model never mentions
   such a file, so inspecting replies cannot see it. Test-run artefacts
   (`__pycache__`, `.pytest_cache`, `*.pyc`, …) are exempt by a narrow regex,
   which is documented as the one hole: a repository without a `.gitignore` would
   otherwise trip the gate on its own by-products.

The `needs_file` reply is the sanctioned way out. It writes nothing at all —
which is why no file is written until *every* declared file has a validated
reply — comments `Blocked: this needs \`<path>\`, …` on the issue, and exits 5.

## The acceptance retry, and the thing it got wrong first

On a failing acceptance command, the **script** decides which file to re-ask. The
first implementation preferred "the declared path named in the failure output",
which is intuitive and wrong: the acceptance command is nearly always a test
invocation, so the *test file's* path appears in the output of every failure,
including failures caused entirely by the implementation. The measured effect was
that the worker re-asked the test file over and over while the broken module sat
untouched, and a recoverable failure became an exhausted retry budget.

The order now is: an implementation file named in the failure, else the first
declared implementation file, else a test file named in the failure, else the
first declared file. The choice and its reason are printed.

If the command still fails, **nothing is committed**. That is the outcome worth
being loud about: a worker that commits after a failing acceptance command looks
like success from the outside, and the dispatcher's validator would only catch it
one step later, on a branch that already exists.

## What is structural, and what is only checked

`ORCHESTRATOR.md`'s note that "anything enforced only by a prompt is a guardrail
against accident, not a control" applies to the worker more than to anything else
in this repo, because the worker is the only component that holds a credential
*and* writes files.

| Prohibition | How it is held |
|---|---|
| never merge a pull request | **no merge call exists** in the program; the token has no merge permission |
| never set a label | **no label call exists**; the string `status:todo` does not appear in the source |
| never edit another issue's body | **no PATCH/PUT/DELETE**: the only writes are create-comment and create-pull |
| never force-push | **no `--force` in any spelling**; the refspec is explicit |
| never commit to the default branch | a branch is created before anything is written |
| never modify the target README | refused in the ticket parser, in the reply validator, and by the scope gate |
| never touch an undeclared file | the three layers above |
| never weaken a test | test functions counted and skip markers compared, per existing file |
| never add an unsanctioned dependency | manifest lines compared against the README |
| never leak the token | one redaction funnel for all output; `GIT_ASKPASS`, so it is in no URL, no `.git/config`, no error message |

The first four are the ones that matter, and they are the ones that are absent
from the code rather than forbidden in a prompt.

## Verifying it

```
./verify-worker.sh            # 116 checks, ~1m40s, no model and no GitHub
./verify-worker.sh image      # + one run inside hermes-worker:latest
```

No credential, no live model, no network: a mock OpenAI-compatible endpoint on
loopback serves [p5-fixtures/model/replies.json](p5-fixtures/model/replies.json),
a fixture GitHub is a JSON file, and the origin is a real local bare repository
built from [p5-fixtures/repo/](p5-fixtures/repo/). `HTTPS_PROXY` points at a dead
port for the whole run, so a call that tried to leave would fail rather than
quietly succeed.

Measured, on the committed fixtures:

```
RESULT: 116 passed, 0 failed
```

What those checks establish, in the order the suites run:

- **Static.** No PATCH/PUT/DELETE, no labels endpoint, no merge call, no
  `--force`, no shell, no token in a URL, and 12 outcomes with 12 distinct exit
  codes.
- **Contract agreement.** `ORCHESTRATOR.md` is parsed and its ticket-format
  section names compared against the worker's; a ticket rendered by the
  *planner's* renderer is round-tripped through the *worker's* parser.
- **Configuration.** A missing token, repo, issue number, malformed repo slug or
  empty endpoint each exits 2 with a message naming what is missing.
- **Ticket conformance.** Nine malformed or ineligible tickets, each broken in
  exactly one way, each refused with exit 4, **zero model calls and no clone**.
- **The positive control.** A well-formed ticket and good replies produce a real
  branch in the origin, exactly one commit, and a diff that is exactly the two
  declared files — with the README and the pre-existing test file byte-identical,
  one pull request whose body says `Closes #31`, and heartbeat comments carrying
  the dispatcher's claim nonce verbatim.
- **Out of scope.** A reply about an undeclared path: exit 3, that file absent,
  the checkout not modified by a single byte, nothing pushed. A reply smuggling
  `extra_files`: refused, and the run still finishes from the clean retry with
  the smuggled file nowhere. A reply about `README.md`: refused, README
  byte-identical. A module that writes an undeclared file **when the acceptance
  command runs**: caught by the git gate, exit 9, nothing committed.
- **Acceptance.** A failing first implementation is retried with the command's own
  output fed back and converges to one commit; exhausting the attempts exits 6
  with no commit, no branch pushed and no pull request.
- **Tests.** A ticket whose acceptance passes while the full suite breaks: exit 7,
  nothing committed, reported. A reply deleting an existing test, then one adding
  `@pytest.mark.skip`: both refused, exit 11, the test file byte-identical — and
  the positive control that the same rejection *recovers* when the next reply
  keeps every test.
- **Dependencies.** A manifest adding `requests` (absent from the README): exit
  10. A manifest with only `pytest` (sanctioned): exit 0.
- **Nothing to do.** A reply identical to what is on the default branch commits
  nothing and opens no empty pull request. A branch that already exists on the
  remote stops the run and is left pointing exactly where it was.
- **Needs a file.** Exit 5, a comment naming the file and the reason, and an
  entirely clean checkout — not even the declared files were written.
- **Across all 26 runs.** Not one label changed on any issue; exactly five pull
  requests, from the five runs that should produce one; the token appears in no
  stdout, no stderr, no issue comment, no model prompt and no git config.
- **Not vacuous.** The mock served 31 calls. A run where it served none is
  reported as a failure, not a clean sweep.

### Mutation-testing the harness

A check that has never failed has never been tested. `./verify-worker.sh` breaks
its own subject twice, in two different places, and requires the suite to go red:

| Mutant | The bug it imitates | Result |
|---|---|---|
| **M1** | `scope_violations()` returns `[]` — the gate never consults git | suite **FAILS**, 4 checks |
| **M2** | `ARTIFACT_RE` widened to `r"."` — the artefact exemption swallows every path | suite **FAILS**, 4 checks |

Both are caught by the same four checks, which is the honest result:

```
caught by: the runtime scope violation gave exit 0
caught by: the scope violation was not reported on the issue
caught by: it committed anyway
caught by: a pull request was opened from an out-of-scope tree
```

Worth reading carefully: under either mutant the worker opens a pull request from
a tree containing a file no ticket declared, and its exit code says `0`. The
reply-level checks (layers 1 and 2) do **not** catch it, because the model never
named that file — which is exactly why the git-level gate exists as a separate
layer, and why the fixture that provokes it creates the file at import time
rather than in a reply.

### In the real image

`./verify-worker.sh image` runs one ticket end to end inside
`hermes-worker:latest` — python 3.12.13 on alpine, read-only rootfs, a single
`/work` tmpfs, uid 10001 — started with the dispatcher's own command template,
`sh -c "P4_ISSUE=31 P4_REPO=… exec /usr/local/bin/p4-worker.sh"`, so the shim and
its `exec` are covered too. Measured: exit 0, both model calls made, the branch
pushed into the mounted origin, a commit touching only the declared files,
nothing needing to write outside `/work`, no token in the container's log, no
`p8-*` container left behind.

## Measured: three live runs against the real model

Local `gpt-oss:20b-64k`, fixture GitHub and a local bare origin (no
`api.github.com`, no remote of any kind). Five model calls in total:

| Ticket | Files | Model calls | Acceptance | Outcome |
|---|---|---|---|---|
| new module + new test | `src/slug.py`, `tests/test_slug.py` | 2 | passed 1st attempt | exit 0, ~40 s wall |
| existing module + new test | `src/util.py`, `tests/test_triple.py` | 2 | passed 1st attempt | exit 0, `+12 −0` |
| existing test file, extended | `tests/test_util.py` | 1 | passed 1st attempt | exit 0, `+4 −0` |

Five for five schema-valid on the first try, no retries, no rejections. The
generated code was ordinary: type hints, a numpydoc docstring, a defensive
`isinstance` check nobody asked for. Notably the third run **extended** an
existing test file without deleting anything, so the weakening check passed on
merit rather than by never being provoked.

Three runs is not a reliability measurement. It is a demonstration that the loop's
shape works with the real model on the intended hardware, and the sample is far
too small to say anything about the tail.

## What the stack needs before a real run

Two changes, both outside the files this component owns:

**`worker.Dockerfile`** — the image has no copy of the worker:

```dockerfile
COPY worker.py /usr/local/bin/worker.py
COPY p4-worker.sh /usr/local/bin/p4-worker.sh
RUN chmod 0755 /usr/local/bin/worker.py /usr/local/bin/p4-worker.sh
```

`p4-worker.sh` is the PID 1 the dispatcher's default `P4_WORKER_CMD` names. It
`exec`s the worker so the exit code survives, and it echoes nothing, because the
container's environment holds a credential.

**`docker-compose.yml`** — the worker needs to know the target project's full
test-suite command, which is repository knowledge rather than ticket knowledge:

```yaml
  hermes-dispatcher:
    environment:
      WORKER_ENV_ALLOWLIST: ${WORKER_ENV_ALLOWLIST:-GITHUB_TOKEN,TARGET_REPO,P5_TEST_COMMAND}
      P5_TEST_COMMAND: ${P4_TEST_COMMAND:-pytest -q}
```

Nothing else. `GITHUB_TOKEN` and `TARGET_REPO` are already injected, the proxy
wiring and `NO_PROXY` are already baked into the image, the model endpoint
defaults to the gate, and no new package is needed — the image already has pytest.
If the allowlist is not extended, the worker falls back to `pytest -q`, which is
right for a Python target and wrong for anything else.

## Where this will still get it wrong

- **A file that does not fit in one reply.** `P5_MODEL_MAX_TOKENS` defaults to
  4096; a 300-line module will be truncated, the JSON will not parse, and the run
  will exit 3 after four attempts having burned ~10 minutes. The remedy is
  smaller tickets — which is `ORCHESTRATOR.md`'s planning rule anyway — but the
  failure will read as "the model is broken" rather than "the ticket is too big".
- **JSON as a transport for code.** Every quote, backslash and newline in the file
  has to survive the model's own escaping. It mostly does; when it does not, the
  reply is truncated JSON and indistinguishable from a length problem.
- **A per-file loop has no cross-file feedback until the command runs.** The
  module is written before the test is asked for. They agree because both prompts
  carry the ticket and each other's contents, but nothing forces it, and the only
  correction available is the acceptance retry.
- **The retry re-asks one file.** If the module and the test are *both* wrong, the
  budget is spent on one of them. The script cannot tell which is at fault, and
  guessing harder is not obviously better than stopping.
- **The dependency check is manifest-only.** A model that adds `import requests`
  to a source file passes it. The import fails at test time and the run exits 6
  or 7, which is a correct outcome reached for the wrong reason.
- **The weakening check counts `def test_*` and skip markers.** A model that
  guts a test's *assertions* while keeping its name passes it. Comparing intent
  is not something a regex can do.
- **The artefact exemption is a hole.** A file written into `__pycache__/` or
  `.pytest_cache/` is not reported as out of scope.
- **A shallow clone plus a push.** Verified against a local origin and, for the
  clone, against a real private repo through the egress proxy. `git push` from a
  `--depth 1` clone to GitHub is normal and expected to work, but that exact
  combination has not been exercised live in this repo.
- **Heartbeats are posted at slow points, not on a timer.** One model call that
  takes longer than `P4_WORKER_TIMEOUT_MINUTES` will be reaped as dead while it is
  in fact working. At ~9 tok/s and a 4096-token cap, one call can take minutes;
  four rejected attempts on one file can approach the 45-minute default.
- **The scope gate runs after the suite, not during it.** A test that writes
  outside the checkout — into `/work`, or `$HOME` — is invisible to it. The
  read-only rootfs is what limits the damage, not this program.
- **`git commit` needs no identity here** because the image sets one system-wide;
  a worker run outside that image relies on the `-c user.name=` flags the script
  passes, which is a detail that will surprise someone eventually.

## What has still not been tested

- A real `api.github.com` round trip from `worker.py`: issue fetch, comment,
  pull-request creation. The REST shapes are the same three calls the planner
  already makes live, but *this* program has only ever talked to the fixture.
- A push to a real remote, therefore also branch protection and a token scoped
  without merge permission.
- Two or three workers at once against one repository — the concurrency the gate's
  three slots and the dispatcher's `P4_MAX_CONCURRENCY` are sized for.
- The dispatcher reading these exit codes. The spawn interface has no way to
  return a worker's exit status (`P4-DISPATCH.md` says so), so today the codes are
  legible to a human running the container and to nothing else.
- Anything but a Python target. The fixture project is Python, `pytest` is the
  default suite command, and the "looks like a test file" heuristics know a
  handful of other conventions without ever having been run against them.

## Files

| File | Purpose |
|---|---|
| `worker.py` | The worker. Script-owned control flow; the model only returns file contents |
| `p4-worker.sh` | The container's PID 1, named by the dispatcher's default `P4_WORKER_CMD` |
| `p4-worker-instructions.md` | What the worker does, and the whole of what the model is told |
| `verify-worker.sh` | 116 checks, plus `image` mode and the mutation control |
| `p5-fixtures/repo/` | The fixture target project: a README, a module, a test, a `conftest.py` |
| `p5-fixtures/issues.json` | The fixture GitHub state: one conforming ticket, nine unusable ones, four more |
| `p5-fixtures/model/replies.json` | 16 canned scenarios: good, wrong-path, prose, dead endpoint, weakening, leaking |

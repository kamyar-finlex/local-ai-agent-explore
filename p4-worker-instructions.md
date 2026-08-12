# Worker runtime instructions

This is what happens when a worker is handed one issue — and, in the second half,
the whole of what the **model** inside it is ever told.

The distinction matters, and it is the reason this file was rewritten. It used to
be a prompt: a numbered procedure handed to a model that was expected to follow
it — post a heartbeat, branch, edit only these files, run this command, open a
pull request. That is the same shape the planner had before `PLANNER.md`, and it
failed the same way four times in a row: the model improvised, misdiagnosed its
own tooling, wrote files it had been told not to, and routed around a tool that
was removed from it. Where the SCRIPT owns control the output has never once been
malformed.

So the procedure below is not advice to a model. It is `worker.py`, and the model
is called exactly once per declared file, to answer one question.

The dispatcher passes two values, both non-secret: `P4_ISSUE` (the issue number)
and `P4_REPO` (`owner/name`). The GitHub token arrives in the container's
environment and is never written into a command line, a commit, a comment or a
log. Everything else has a default that is correct inside the sandbox.

Where this file and `ORCHESTRATOR.md` disagree, `ORCHESTRATOR.md` wins.

---

## What the script does, in order

1. **Config, before anything else.** Missing token, repo or issue number ends the
   run with exit `2` and a message naming what is missing. A worker that starts
   without a token fails deep inside a `git push`, twenty minutes later, in a way
   that reads like a network fault.

2. **Fetch the issue and parse it** against `ORCHESTRATOR.md`'s ticket format:
   `Goal`, `Files touched`, `Details`, `Acceptance criteria`, and optionally
   `Blocked-by`. A ticket that does not conform is **refused** — exit `4`, with a
   `<!-- p4-defect -->` comment on the issue saying exactly which section is
   wrong. This happens **before the clone and before the first model call**,
   because a malformed ticket is a planning defect to report, not something to
   guess around: a worker that guesses produces a plausible pull request against
   the wrong intent, which is the most expensive output this system can emit.
   Refused too: an issue carrying `spec`, and a closed issue.

3. **Clone shallow, branch** as `issue-<N>-<short-slug>`. If that branch already
   exists on the remote, the run stops with exit `8` rather than force-pushing.

4. **One model call per declared file.** Each call carries the goal, the details,
   the acceptance command, the target project's README, the other declared paths
   with their current contents, and the current contents of the file being asked
   about. It asks for the complete new contents of that one file. The reply is
   validated on receipt; a rejected reply is retried with the rejection fed back,
   and when the retries are exhausted the run STOPS and prints the raw reply
   (exit `3`). Nothing is invented to fill the gap.

   Nothing is written to disk until **every** declared file has a validated
   reply. That is what makes outcome (7) below genuinely write-free.

5. **Run the acceptance command**, exactly as the ticket states it, as one
   command with no shell. If it fails, the script — not the model — picks which
   file to re-ask, feeds the command's own output back, rewrites that one file and
   runs the command again, up to `P5_ATTEMPTS` times (default 3). If it still
   fails: exit `6`, the failure is reported on the issue, and **nothing is
   committed**. Then the project's full suite; if a test the worker did not write
   now fails, that is a real finding — exit `7`, reported, not repaired.

6. **The scope gate, before anything is committed.** `git status` must show no
   change outside `Files touched`. A file the *acceptance run itself* created
   counts: the model never names it, so only a git-level check can see it.
   Violation: exit `9`, nothing committed. Then `git add` is given the declared
   paths only, and the staged diff is re-checked against the same list.

7. **Commit, push, open the pull request** with `Closes #N`, the acceptance
   command's output and the suite's summary in the body. Then a final comment on
   the issue for the human. Exit `0`.

Heartbeats (`<!-- p4-heartbeat -->`, carrying the dispatcher's claim nonce
verbatim) are posted by the script at each point it is about to be slow — before
a model call, before a test run, before the push. A worker that stops
heartbeating is assumed dead and its ticket is taken away after
`P4_WORKER_TIMEOUT_MINUTES` (default 45).

## Outcomes, one exit code each

`worker.py --exit-codes` prints this table; the dispatcher reads the number
rather than parsing prose.

| Code | Outcome | Meaning |
|---|---|---|
| 0 | `pr-opened` | acceptance and full suite passed, pull request opened |
| 1 | `internal-error` | unexpected failure in the worker itself |
| 2 | `config-missing` | token, repo or issue number absent; nothing attempted |
| 3 | `model-unusable` | no schema-valid reply after the retries; nothing committed |
| 4 | `ticket-malformed` | planning defect; refused before clone and before the model |
| 5 | `needs-file` | needs a file outside `Files touched`; commented, wrote nothing |
| 6 | `acceptance-failed` | acceptance command failed after the retries; nothing committed |
| 7 | `suite-failed` | a test the worker did not write failed; nothing committed |
| 8 | `git-failed` | clone, push or pull-request creation failed |
| 9 | `scope-violation` | a file outside the declared list changed; nothing committed |
| 10 | `unsanctioned-dep` | a dependency outside the README's `## Implementation constraints` list |
| 11 | `test-weakened` | the reply removed, skipped or xfailed a test |

Exit `5` is the one worth dwelling on. **Stopping is a correct, useful outcome**:
it tells a human the plan was wrong. Editing the extra file silently is the worst
thing a worker can do, because the dispatcher's validator will reject the pull
request anyway and the worker will have collided with whoever owns that file.

---

## What the model is told

One system line, and one user message per file. There is no conversation, no
tool, no shell, and no second question:

```
TASK: return the complete new contents of ONE file: <path>

TARGET FILE: <path>

TICKET
  goal: <the ticket's Goal>
  acceptance command (it will be run for real): <the ticket's Acceptance criteria>
  details:
    <the ticket's Details>

FILES THIS TICKET MAY TOUCH (no others exist for you):
  - src/thing.py   <-- this call
  - tests/test_thing.py

TARGET PROJECT README (the specification; do not modify it)
  <clipped README>

<the file's current contents, if it exists>
<the other declared files' current contents>
<on a retry: the acceptance command and the output it failed with>

RULES
  - Answer about <path> and no other file. Other paths are other calls.
  - Do not create, mention as created, or write any file outside the list above.
  - Never modify the README. Never delete or skip a test.
  - Add no third-party dependency outside the packages the README sanctions:
    <the names from its '## Implementation constraints' section, listed here
     verbatim; or "Only the standard library is sanctioned" when it names none>
  - Return the WHOLE file, not a diff, not a fragment, not an ellipsis.

REPLY with exactly one JSON object:
  {"path": "<the requested path, verbatim>", "contents": "<the complete file>"}
If, and only if, this file genuinely cannot be written without a file that is
NOT in the list above, reply instead with:
  {"needs_file": "<the path you would need>", "reason": "<one line>"}
```

The reply is checked before it becomes a byte on disk:

- `path` must equal the path that was asked about. A reply about a different file
  is the model writing outside the ticket, and it is refused rather than filtered.
- a `files` / `extra_files` / `additional_files` key is a refusal, not something
  to ignore quietly.
- `contents` must be a non-empty string (or a list of line strings) under
  `P5_MAX_FILE_BYTES`.
- for an existing test file: no test function may disappear and no `skip`/`xfail`
  marker may appear that was not there before.
- for a dependency manifest: no package outside the target README's
  `## Implementation constraints` list, compared by whole name.

## Never

The first four of these are **structural** — there is no code path in `worker.py`
that can do them, which is the only kind of guarantee worth having. The rest are
enforced by the checks listed above.

- Never **merge** a pull request. There is no merge call, and the token has no
  merge permission.
- Never move an issue to `status:todo`, or set any label at all. There is no
  label call; the dispatcher owns `status:in-progress` and humans own the rest.
  Approval is a human act and relabelling your own ticket removes the review gate.
- Never edit another issue's description. The only writes are: create a comment,
  create a pull request.
- Never **force-push**, and never commit to the default branch. The push refspec
  is explicit and carries no force flag in any spelling.
- Never edit the target project's **README** — refused in the ticket parser, in
  the reply validator, and again by the scope gate.
- Never touch a file outside `Files touched`, including one created by the code
  under test.
- Never weaken, skip or delete a test to make a run pass. A failing test is the
  most useful output this system produces.
- Never add a dependency the target README's `## Implementation constraints`
  section does not name. A README without that section sanctions nothing.
- Never print, echo, commit or comment the token. Everything the worker prints
  goes through one redaction funnel, and the token reaches git through
  `GIT_ASKPASS` rather than a URL, so it is in no remote, no `.git/config` and no
  error message.

## What a worker can reach

Nothing except an HTTPS proxy with a domain allowlist (`EGRESS.md`):
`github.com` for git, `api.github.com` for the issue and the pull request. The
model gate is a plain-http host on the isolated network and is covered by
`NO_PROXY`; inference deliberately does not go through the proxy, because the
allowlist would deny it and the failure would look exactly like "the model is
down".

Package registries are deliberately absent. If an install fails with a proxy
refusal, that is the "no new dependencies" rule enforced structurally rather than
by instruction.

## If something is ambiguous

The script stops and says so on the issue. An unfinished ticket with an
explanation is cheap; a ticket that quietly did something else is expensive. The
dispatcher never repairs a worker's output — it only reports what it found — so
an ambiguity papered over here survives all the way to a human.

# Worked example — five tickets for a small service

A deliberately tiny plan, kept as a shape to copy rather than a project to build.
The rendered issues are checked in as the validator's fixtures (`p3-fixtures/good`),
so this example is verified by `verify-planner.sh` on every run.

## The layout, chosen first

```
pyproject.toml            packaging + pytest config      owned by T1
src/example/__init__.py   package entrypoint and wiring  owned by T2, edited by T5
src/example/store.py      the data model                 owned by T3
src/example/api.py        the HTTP surface               owned by T4
tests/test_smoke.py       proves the runner works        owned by T1, edited by T5
tests/test_store.py       T3's tests
tests/test_api.py         T4's tests
```

Seven files, five tickets, and every file has exactly one owner. The two files
with a second editor (`__init__.py`, `test_smoke.py`) are edited only by T5,
which is blocked by their owners — so no two tickets that could run together
share a path.

## The tickets

```
T1  p1  Create the package skeleton and test runner
        files      pyproject.toml, tests/test_smoke.py
        acceptance pytest -q tests/test_smoke.py

T2  p1  Add the package entrypoint module            blocked-by T1
        files      src/example/__init__.py
        acceptance python -c "import example"

T3  p2  Implement the in-memory record store         blocked-by T2
        files      src/example/store.py, tests/test_store.py
        acceptance pytest -q tests/test_store.py

T4  p2  Implement the HTTP request router            blocked-by T2
        files      src/example/api.py, tests/test_api.py
        acceptance pytest -q tests/test_api.py

T5  p3  Wire the store into the router at startup    blocked-by T3, T4
        files      src/example/__init__.py, tests/test_smoke.py
        acceptance pytest -q tests/test_smoke.py
```

## What the shape is doing

```
wave 1: T1          foundation: manifest, runner, one trivial test
wave 2: T2          the entrypoint, created once so nobody races for it
wave 3: T3, T4      the two independent concerns, dispatchable together
wave 4: T5          the single wire-up ticket, owner of the shared edits
```

- **T1 is concrete.** Not "set up the project": named files, and the test runner
  itself as the acceptance command.
- **T2 exists only to create a file.** That looks like overhead until two feature
  tickets both need the package to exist and both try to create it.
- **T3 and T4 never import each other.** That is what keeps wave 3 parallel; the
  import happens in T5.
- **T5 is the only ticket that edits a file it did not create**, and it is blocked
  by both owners, which is the sole sanctioned way to share a file.

## The command that writes one of them

```bash
python3 $P3/p3-plan.py add --id T3 --priority 2 --blocked-by T2 \
  --title "Implement the in-memory record store" \
  --files src/example/store.py,tests/test_store.py \
  --acceptance "pytest -q tests/test_store.py" \
  --goal "Records can be added, fetched by id and listed." \
  --details "Implement the Store class described under Data model in the README:
add(record) returning an id, get(id) raising KeyError when absent, and list()
returning insertion order. Cover all three in tests/test_store.py, including the
KeyError path."
```

Note what the Details do *not* do: they never restate the README, they point at
the section that specifies the behaviour and add only what the worker cannot
infer from it.

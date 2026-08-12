# example-target

A deliberately tiny stand-in for "the target project" in `verify-worker.sh`. It
is NOT the real target of this experiment and it describes no real product: it
exists so a worker can be handed a ticket against a repository whose contents
are fixed, committed and identical on every run.

Nothing about this file is trip-planner-shaped, on purpose. The worker must work
against **any** repository, so the fixture deliberately has no domain at all.

There is no API here, nothing requests anything over a network, and no module is
re-exported from another. Those three sentences are bait, and they are load
bearing: `api`, `requests` and `re` are all real packages on PyPI, and each one
appears as a substring of the prose above. A dependency check that searched this
file for a package name would sanction all three. The check does not search this
file — it reads one section, by name, and compares whole names.

## Layout

- `src/` — the package. Imported as `src.<module>`; there is no `__init__.py`
  because implicit namespace packages are enough here.
- `tests/` — the test suite, one file per module.
- `conftest.py` — empty. It exists only so pytest puts the repository root on
  `sys.path`, which is what makes `from src.util import ...` work from `tests/`.

## Implementation constraints

The implementation may use these Python packages and no others. Anything else
must be solved with the standard library: a ticket that needs another package is
a ticket a human has to sanction here first, by editing this section.

- pytest

The heading above is the one the worker looks for by name, spelled exactly that
way — see `ORCHESTRATOR.md`, "What the specification must contain". Prose in this
section, including this paragraph, carries no permission; only the `- ` lines do.

## Running the tests

The full suite:

    pytest -q

One file, which is the shape every ticket's acceptance criterion takes here:

    python3 -m pytest -q tests/test_util.py

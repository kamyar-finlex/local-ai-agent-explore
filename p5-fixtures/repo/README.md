# example-target

A deliberately tiny stand-in for "the target project" in `verify-worker.sh`. It
is NOT the real target of this experiment and it describes no real product: it
exists so a worker can be handed a ticket against a repository whose contents
are fixed, committed and identical on every run.

Nothing about this file is trip-planner-shaped, on purpose. The worker must work
against **any** repository, so the fixture deliberately has no domain at all.

## Layout

- `src/` — the package. Imported as `src.<module>`; there is no `__init__.py`
  because implicit namespace packages are enough here.
- `tests/` — the test suite, one file per module.
- `conftest.py` — empty. It exists only so pytest puts the repository root on
  `sys.path`, which is what makes `from src.util import ...` work from `tests/`.

## Dependencies

The Python standard library and **pytest**. Nothing else is sanctioned: a ticket
that needs another package is a ticket a human has to approve first, and the
worker's container cannot reach a package registry anyway.

## Running the tests

The full suite:

    pytest -q

One file, which is the shape every ticket's acceptance criterion takes here:

    python3 -m pytest -q tests/test_util.py

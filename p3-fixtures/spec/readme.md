# example-service

A tiny record service. This file is planning INPUT only — nothing in this
repository builds it. It exists so the planner can be exercised against a README
that looks like a real one, offline and without a target repository.

## Setup

Python 3.11+, a `src/` layout, and a dependency manifest in `pyproject.toml`.

## Implementation constraints

The implementation may use these Python packages and no others. Anything else
must be solved with the standard library.

- pytest

## Data model

A `Store` holds records in memory, keyed by a string id. It supports adding a
record, fetching one by id, and listing all of them. Fetching an id that was
never added raises `KeyError`.

## HTTP surface

A router maps a method and a path to a handler callable. `register` adds a
route; `dispatch` looks one up and calls it. An unknown route returns 404. The
router does not open a socket — it is a pure mapping, so it can be tested
directly.

## Assembly

Importing the package builds one `Store`, registers the three record routes on
one router, and exposes the result as `example.app`.

## Testing

`pytest -q`. Every module has one test file beside it under `tests/`.

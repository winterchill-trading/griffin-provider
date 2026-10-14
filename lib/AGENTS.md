# AGENTS.md (lib/)

Library `griffin_provider` (public name `griffin-provider`).

- `adapter.ml` is the only module that calls Griffin; the `*_map` modules, `Units` and
  `Refs` are pure and tested on recorded bodies.
- `Store` holds the links Griffin cannot (customer ids, accounts per currency, transfers);
  the in-memory implementation is for tests and tools. Libraries never persist.
- A new Griffin event type: map it in `Adapter.handle_event` with an id derived from the
  resource, and add the row to `../docs/mapping.md`.
- Build: `dune build --root .. @griffin-provider/all` from the repository root.

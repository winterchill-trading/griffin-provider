# AGENTS.md (test/)

- `test_*_map.ml`, `test_units.ml`, `test_uk_account.ml`, `test_cop.ml`: mappings on the
  redacted sandbox bodies in `fixtures/` (keep fixtures free of real ids, names, e-mails).
- `fake_griffin.ml`: an in-memory Griffin behind `Transport.create ~send`;
  `test_adapter.ml` drives the adapter through it. `test_key.ml` signs webhook deliveries
  with a throwaway P-521 test key.
- `test_store.ml` pins the transfer record digest.
- `live/`: the conformance suite and the GBP walk; they print a skip line unless
  `GRIFFIN_LIVE_TESTS=1` and the key are set, and create sandbox objects when they run.
- Run `dune build --root .. @griffin-provider/runtest`; promote expect output with
  `--auto-promote` after reading the diff. Print times as fixed values, never the clock.

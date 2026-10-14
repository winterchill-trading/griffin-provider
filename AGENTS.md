# AGENTS.md

## Purpose

This library implements `banking-provider`'s `Provider.S` and `Sandbox.S` over the Griffin
API (`griffin-client`): UK customers as legal persons, GBP accounts with sort codes, Faster
Payments and book transfers, Confirmation of Payee, and Griffin events normalized into
`banking-provider` events. It is the only code that knows both the provider-neutral
interface and Griffin; cards, swaps, standing orders, crypto and SCA answer an error.

## Layout

| Path | Holds |
| --- | --- |
| `lib/` | Library `griffin_provider`: `Adapter`, `Store`, `Refs`, `Uk_account`, `Units`, `Kyc_map`, `Account_map`, `Tx_map`, `Griffin_time` (see `lib/AGENTS.md`) |
| `bin/` | `griffin-provider` CLI: KYC status, accounts, balance, UK details, statement, CoP, events (see `bin/AGENTS.md`) |
| `test/` | Mapping tests on recorded bodies, adapter tests against an in-memory Griffin, live runners in `test/live/` (see `test/AGENTS.md`) |
| `examples/` | `onboard_and_pay.ml`, built in CI (see `examples/AGENTS.md`) |
| `docs/` | `mapping.md` (operations, events, KYC, payments, gaps), `api-notes.md` (sandbox findings) |
| `.github/` | CI workflow |
| `dune-project`, `griffin-provider.opam` | Package metadata; the `.opam` file is generated |

## Build, test, docs

Run from this directory; the workspace root `..` holds the sibling checkouts.

```sh
opam exec --switch 5.2.0+ox -- dune build --root .. @griffin-provider/all
opam exec --switch 5.2.0+ox -- dune build --root .. @griffin-provider/runtest
opam exec --switch 5.2.0+ox -- dune build --root .. @griffin-provider/doc
DUNE_BUILD_DIR=_build-griffin-provider opam exec --switch 5.2.0+ox -- dune build --root .. @griffin-provider/all
```

The last line gives parallel work its own build directory (resolved from the workspace
root). Live runs need the sandbox key in the gitignored `.env`:

```sh
set -a; . ./.env; set +a
GRIFFIN_LIVE_TESTS=1 opam exec --switch 5.2.0+ox -- dune build --root .. @griffin-provider/runtest
```

Standalone: pin the siblings listed in `.github/workflows/ci.yml` from GitHub, then
`opam install . --deps-only --with-test && dune build && dune test`.

## Conventions

- Formatting: `dune build --root .. @griffin-provider/fmt --auto-promote`, after the tests
  pass. Never `dune fmt` at the workspace root.
- Every module has an `.mli` with odoc on every public value; `open! Core`, labelled
  arguments, `ppx_jane`.
- `Store.Transfer_record` is stable with a pinned `[%bin_digest]` (`test/test_store.ml`);
  changing it is a version decision.
- Event ids are derived from Griffin data so poll, webhook and status queries agree; keep
  them that way when adding an event.
- Griffin has no idempotency keys: every create goes through the `Store` first.
- Comments for humans at non-obvious choices (the `Intraledger` rail for GBP, the 422
  refusal handling). Add a `CHANGES.md` "Unreleased" entry for user-visible changes, and
  update `docs/mapping.md` when an operation's mapping changes.

## Dependencies and dependents

- Depends on: `money`, `ledger`, `kyc-core`, `payments-core`, `card-core`,
  `banking-provider`, `griffin-client` (and `fixed-decimal` through them).
- Used by: services that route GBP accounts to Griffin through `banking-provider`.
- CI pin order: `fixed-decimal`, `money`, `ledger`, `kyc-core`, `payments-core`,
  `card-core`, `banking-provider`, `griffin-client`.

## CI

`.github/workflows/ci.yml` runs the `ox-setup` action with those pins (cached switch),
`dune build`, `dune build @examples/all` and `dune test`; the live runners print a skip
line because CI has no credentials. The `obj-magic` job rejects `Obj.magic`. Check with
`gh run list --limit 1`, then at most one `gh run watch <id> --exit-status`.

## Pitfalls

- payments-core's SEPA rails validate EUR, so GBP payments are drafted and reported on
  `Intraledger`; a GB IBAN carries the sort code and account number.
- banking-provider's conformance suite opens an EUR account first, so only 4 of 11
  scenarios can pass here; `test/live/walk.ml` checks the money properties in GBP.
- Sandbox accounts start with GBP 1m and payments above GBP 1m are refused with
  `payment-amount-exceeds-scheme-limit` before the balance is checked.
- `submission-status-reason` (e.g. `insufficient-funds`) is not in griffin-client's
  `Submission.t`; the adapter reads the raw JSON.
- Inside `Deferred.Or_error.Let_syntax`, `>>|` maps the `Or_error`; use `Deferred.map` on
  plain deferreds.
- `Pipe.close_read` drops queued events; read with `Pipe.read_now'` first in tests.

## Where to read more

- `README.md`, `docs/mapping.md`, `docs/api-notes.md`, `CHANGES.md`.
- `../specs/repos/griffin-provider.md` when present.
- Skills in `../oxcaml-claude-skills/skills/`: `banking-standards`, `janestreet-ocaml-style`.
- `../oxcaml-claude-skills/AGENTS.md`: the workspace-wide guide; `../oxcaml-claude-skills/GOTCHAS.md`.

## Never do

- Install or upgrade opam packages on the shared `5.2.0+ox` switch without a dry run;
  abort if the plan touches `ocaml-variants`, `core`, `base`, `async` or `ppx_jane`.
- Publish, tag or release.
- Commit `.env` or print the API key; credentials come only from the environment.
- Call sandbox endpoints that change organization settings (webhooks, keys).
- Poll CI in a loop.

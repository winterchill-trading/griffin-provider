# griffin-provider

`banking-provider`'s `Provider.S` and `Sandbox.S` implemented over the Griffin v0 API
(`griffin-client`): UK customers as legal persons with onboarding checks and decisions,
GBP accounts with sort codes, Faster Payments and book transfers, Confirmation of Payee,
statements, and Griffin's event log and webhooks normalized into `banking-provider`
events. Sandbox by default. Cards, swaps, standing orders, crypto and SCA are not offered
and answer an error saying so.

## Why separate

`banking-provider` describes what an application needs from any banking-as-a-service
provider and stays free of provider names; `griffin-client` is a plain SDK for one API.
This adapter is the only place that knows both, so swapping providers, or running the fake
provider in tests, never touches application code.

## Quick start

```sh
cp .env.example .env               # a g-test- sandbox key
set -a; . ./.env; set +a
dune build
GRIFFIN_LIVE_TESTS=1 dune test     # also runs the conformance suite and the GBP walk
dune exec examples/onboard_and_pay.exe
dune exec griffin-provider -- accounts lp.XXXX
```

```ocaml
module A = Griffin_provider.Adapter

let%bind.Deferred.Or_error t = A.of_env () in
let%bind.Deferred.Or_error customer = A.create_customer t ~customer_id ~person in
(* After the onboarding decision. *)
let%bind.Deferred.Or_error account = A.open_account t customer.id Money.Currency.gbp in
let%bind.Deferred.Or_error details = A.uk_details t account.id in   (* sort code *)
let%bind.Deferred.Or_error check =
  A.confirm_payee t ~customer:customer.id ~name:"Example Payee" payee
in
A.initiate_transfer t ~from:account.id transfer   (* a Transfer.draft on Intraledger *)
```

A service passes its own `Store.t` (persisted links between our ids and Griffin's) and
hands each webhook delivery to `ingest_webhook`. Without a public webhook URL the adapter
polls the organization's event log while `events` has a subscriber.

Payees are written as `Internal` beneficiaries naming a sort code and account number
(`04-00-04 12345678`) or a Griffin account id (`ba.…`, a book transfer), or as a
`Bank_account` with a GB IBAN. GBP payments are drafted and reported on the `Intraledger`
rail because payments-core has no Faster Payments rail yet (see Known gaps).

## Environment

| Variable                   | Required | Purpose                                                       |
| -------------------------- | -------- | ------------------------------------------------------------- |
| `GRIFFIN_API_KEY`          | yes      | a `g-test-` key; others are refused unless `~live:true`        |
| `GRIFFIN_API_BASE_URL`     | no       | defaults to `https://api.griffin.com`                          |
| `GRIFFIN_SIGNING_KEY`, `GRIFFIN_SIGNING_KEY_ID` | no | RFC 9421 request signing (see griffin-client)   |
| `GRIFFIN_LIVE_TESTS`       | no       | `1` lets `dune test` run the live conformance suite and walk  |
| `GRIFFIN_CONFORMANCE_ONLY` | no       | runs only the scenarios whose name contains this text          |
| `GRIFFIN_CONFORMANCE_STRICT` | no     | `1` makes conformance failures fail `dune test`                |

Credentials are read only from the environment and never logged.

## Modules

| Module        | What it does                                                                   |
| ------------- | ------------------------------------------------------------------------------ |
| `Adapter`     | `Provider.S`, `Sandbox.S`, Confirmation of Payee, UK details, webhook ingestion, the poller |
| `Store`       | links Griffin cannot hold (our customer ids, accounts per currency, transfers), with an in-memory implementation |
| `Refs`        | customer and account refs from Griffin resource URLs                           |
| `Uk_account`  | sort codes and account numbers, from text or a GB IBAN                          |
| `Units`       | Griffin GBP amounts to `Money`                                                  |
| `Kyc_map`     | person to claims; legal persons, verifications and decisions to kyc-core steps, status and events |
| `Account_map` | accounts, balances, statements                                                  |
| `Tx_map`      | submissions and admissions to transfer states, deposits and events              |
| `Griffin_time` | ISO timestamps                                                                 |

`docs/mapping.md` lists every operation with its Griffin endpoints, every event, the KYC,
payment and Confirmation of Payee mappings, and the gaps. `docs/api-notes.md` records what
the sandbox showed.

## Coverage

"Live" means exercised on the Griffin sandbox on 2026-10-14 by the conformance run, the
GBP walk (`test/live/walk.ml`) or the example; "offline" means against recorded bodies
or the in-memory Griffin in `test/`.

| Operation                         | Verified                        |
| --------------------------------- | ------------------------------- |
| `create_customer` (idempotent)    | live, offline                   |
| `update_customer`                 | live                            |
| `start_verification`, `kyc_status`, KYC events | live, offline      |
| `simulate_kyc_decision` | approve live and offline, decline offline |
| `open_account` (idempotent, recovered by owner), `accounts`, `uk_details` | live, offline |
| `balance`, `statement`            | live, offline                   |
| `initiate_transfer` by Faster Payments and book transfer, resend, refusal above the scheme limit, failure for insufficient funds | live, offline |
| `transfer`, transfer events       | live, offline                   |
| `cancel_transfer`                 | offline                         |
| `simulate_deposit` (Faster Payments) and the deposit event | live   |
| `confirm_payee`, `simulate_confirm_payee` (match, close match, no match, account not found) | live, offline |
| `ingest_webhook` (verified, tampered, wrong host) | offline (own P-521 key); the forged delivery live |
| `ping`                            | local Ping (live)                |
| refusals (cards, EUR, SCA, swaps, standing orders) | live, offline  |

## Conformance

`test/live/conformance.ml` runs `banking-provider`'s `Conformance` functor against the
sandbox when `GRIFFIN_LIVE_TESTS=1` and the key is set; otherwise it prints one line and
passes, which is what CI sees. It uses the suite's defaults unchanged (10 second timeout
per wait, 50 ms polling, the suite's synthetic German resident).

Run on 2026-10-14: 4 passed, 7 failed.

| Scenario                                                       | Result |
| -------------------------------------------------------------- | ------ |
| create_customer is idempotent on our customer id               | pass   |
| a KYC approval is published as an event and reported by kyc_status | pass (9.2 s of the 10 s timeout) |
| an approved customer gets an EUR account with an IBAN          | fail: GBP only |
| a deposit is published once and credits the balance            | fail: GBP only |
| a payment confirmed by SCA settles and debits amount plus fee  | fail: GBP only |
| initiating the same transfer twice pays once                   | fail: GBP only |
| a payment above the balance does not leave the account         | fail: GBP only |
| a wrong SCA code is refused without naming a factor            | fail: GBP only |
| a webhook with a bad signature is refused                      | pass   |
| a test delivery arrives as a Ping event                        | pass (Ping published locally) |
| a virtual card is approved, and declined with 57 once frozen   | fail: GBP only (and no cards) |

Every failure is the suite opening an EUR account with an IBAN first: the suite's money
scenarios are written in EUR over SEPA, and Griffin holds GBP only. The GBP walk
(`test/live/walk.ml`) checks the same properties in GBP and passed on the same day:
customer and onboarding, one account per customer, a deposit published once and credited,
a Faster Payment settled and debited by amount plus fee (zero), the same transfer twice
paying once, a book transfer between customers, payments above the balance not leaving
the account (`Failed Insufficient_funds`, for book transfers and Faster Payments), a
balanced statement, Confirmation of Payee, and refusals for cards and EUR.

## Known gaps

- **No Faster Payments rail or UK account destination in payments-core, no UK details in
  `Account.Address`.** SEPA rails accept EUR only, so GBP payments are drafted and
  reported on `Intraledger` (the payee's sort code and number travel in the beneficiary
  and counterparty text), and accounts list no addresses; `uk_details` gives the sort code.
  A `Faster_payments` rail, a UK account destination and address would remove both
  workarounds.
- **No `verify_payee` in `Provider.S`**: Confirmation of Payee is `Adapter.confirm_payee`.
- **The conformance suite is EUR, SEPA and cards only**, so 7 of its 11 scenarios cannot
  pass against a GBP provider; a suite parameterized by currency and rail would let the
  GBP walk's checks run there.
- **No idempotency keys at Griffin**: the `Store` is what makes creates idempotent; a
  service must persist it (only the in-memory store ships here). Accounts are also found
  again by owner; a legal person created by a lost response is not.
- **Tier**: Griffin verifies identity and address electronically, not e-mail, mobile or
  liveness, so an approved customer's derived kyc-core tier stays `T0`.
- **Sandbox**: no inbound simulator (deposits are paid from another sandbox account),
  every payment is delivered (`simulate_transfer_outcome` refuses), and every new account
  starts with GBP 1m, so a balance equal to the deposit never holds.
- **Webhooks**: no endpoint here receives real deliveries, and `ping` publishes its own
  `Ping` by default instead of asking Griffin for a test delivery to the organization's
  single webhook, which may belong to another integration. Verification is tested with our
  own P-521 key in Griffin's format.
- **Decline and resubmission**: a declined decision is tested offline only, and Griffin
  has no resubmission request (`Request_resubmission` is refused).
- Cards, swaps, standing orders, crypto and SCA are not offered.

## Tests

- `dune test`: mapping tests on recorded, redacted sandbox bodies; adapter flows against
  an in-memory Griffin (`test/fake_griffin.ml`); the CLI and example build; the live
  runners print a skip line without credentials.
- `GRIFFIN_LIVE_TESTS=1 dune test` with `.env` loaded: the conformance suite and the GBP
  walk on the sandbox. Each run creates sandbox legal persons, accounts and payments.

See also `AGENTS.md` (orientation for agents working in this repository), `docs/mapping.md` and `docs/api-notes.md`.

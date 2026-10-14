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
(* account.addresses = [Uk_account { sort_code; account_number; _ }] *)
let%bind.Deferred.Or_error check = A.verify_payee t ~customer:customer.id beneficiary in
A.initiate_transfer t ~from:account.id transfer   (* a Transfer.draft on Faster_payments *)
```

A service passes its own `Store.t` (persisted links between our ids and Griffin's) and
hands each webhook delivery to `ingest_webhook`. Without a public webhook URL the adapter
polls the organization's event log while `events` has a subscriber.

Transfers on `Faster_payments` go to a beneficiary's `Uk_account` (or a GB IBAN) and carry
`Uk_domestic` details with Griffin's end-to-end id; transfers on `Intraledger` are book
transfers to an `Internal` beneficiary naming a Griffin account id (`ba.…`). Accounts
report their sort code and account number as `Account.Address.Uk_account`. In the sandbox,
new accounts are emptied of the GBP 1m Griffin credits them with
(`Config.empty_sandbox_accounts`), so balances start at zero as real accounts do.

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
| `Store`       | links Griffin cannot hold (our customer ids, accounts per currency, transfers with their V2 rail), with an in-memory implementation |
| `Refs`        | customer and account refs from Griffin resource URLs                           |
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
| `simulate_kyc_decision`           | approve live and offline, decline offline |
| `open_account` (idempotent, recovered by owner, emptied in the sandbox), `accounts`, `enrich_account` with the UK address | live, offline |
| `balance`, `statement`            | live, offline                   |
| `initiate_transfer` on Faster Payments and book transfers, resend, refusal above the scheme limit, failure for insufficient funds | live, offline |
| `transfer`, transfer events       | live, offline                   |
| `cancel_transfer`                 | offline                         |
| `simulate_deposit` (Faster Payments) and the deposit event | live   |
| `verify_payee` (Confirmation of Payee), `simulate_payee_check` (every answer) | live, offline |
| `confirm_payee`, `simulate_confirm_payee` (Griffin's per-request simulator) | live (earlier run the same day), offline |
| `ingest_webhook` (verified, tampered, wrong host) | offline (own P-521 key); the forged delivery live |
| `ping`                            | local Ping (live)                |
| refusals (cards, EUR, SCA, swaps, standing orders, CHAPS and Bacs out) | live, offline |

## Conformance

`test/live/conformance.ml` runs `banking-provider`'s `Conformance` functor with its GBP
configuration (`Config.gbp`: Faster Payments, a UK resident, GBP 100 in and GBP 30 out,
the suite's 10 second timeouts and 50 ms polling) against the sandbox when
`GRIFFIN_LIVE_TESTS=1` and the key are set; otherwise it prints one line and passes, which
is what CI sees.

Run on 2026-10-14: 11 passed, 1 failed.

| Scenario                                                       | Result |
| -------------------------------------------------------------- | ------ |
| create_customer is idempotent on our customer id               | pass   |
| a KYC approval is published as an event and reported by kyc_status | pass |
| an approved customer gets a GBP account with a sort code and account number | pass |
| a deposit is published once and credits the balance            | pass   |
| a payment confirmed by SCA settles and debits amount plus fee  | pass (no challenge) |
| initiating the same transfer twice pays once                   | pass   |
| a payment above the balance does not leave the account         | pass   |
| a wrong SCA code is refused without naming a factor            | pass (no challenge) |
| a webhook with a bad signature is refused                      | pass   |
| a test delivery arrives as a Ping event                        | pass (Ping published locally) |
| a virtual card is approved, and declined with 57 once frozen   | fail: Griffin issues no cards |
| verify_payee answers, and a simulated answer is returned       | pass   |

The GBP walk (`test/live/walk.ml`) passed the same day: onboarding and a customer update,
one account per customer starting at zero, a Faster Payments deposit published once and
credited, a Faster Payment settled and debited, the same transfer twice paying once, a
book transfer between customers, payments above the balance ending
`Failed Insufficient_funds` (book transfer and Faster Payments), a balanced statement,
`verify_payee` on the customer's own account and every simulated answer, and refusals for
cards and EUR.

## Known gaps

- **Cards, swaps, standing orders, crypto and SCA are not offered**; the conformance
  suite's card scenario fails for that reason.
- **Outgoing CHAPS and Bacs** are refused: Griffin's API sends Faster Payments and book
  transfers. Inbound CHAPS and Bacs are reported on their rails.
- **No idempotency keys at Griffin**: the `Store` is what makes creates idempotent; a
  service must persist it (only the in-memory store ships here). Accounts are also found
  again by owner; a legal person created by a lost response is not.
- **Tier**: Griffin verifies identity and address electronically, not e-mail, mobile or
  liveness, so an approved customer's derived kyc-core tier stays `T0`.
- **Sandbox**: no inbound simulator (deposits are paid from another sandbox account), every
  payment is delivered (`simulate_transfer_outcome` refuses), and the opening GBP 1m is
  moved away by a book transfer that shows on statements. Simulated payee answers are
  returned as fixed; Griffin's own simulator words close matches itself.
- **Webhooks**: no endpoint here receives real deliveries, and `ping` publishes its own
  `Ping` by default instead of asking Griffin for a test delivery to the organization's
  single webhook, which may belong to another integration.
- **Decline and resubmission**: a declined decision is tested offline only, and Griffin
  has no resubmission request (`Request_resubmission` is refused).

## Tests

- `dune test`: mapping tests on recorded, redacted sandbox bodies; adapter flows against
  an in-memory Griffin (`test/fake_griffin.ml`); the CLI and example build; the live
  runners print a skip line without credentials.
- `GRIFFIN_LIVE_TESTS=1 dune test` with `.env` loaded: the conformance suite and the GBP
  walk on the sandbox. Each run creates sandbox legal persons, accounts and payments.

See also `AGENTS.md` (orientation for agents working in this repository), `docs/mapping.md` and `docs/api-notes.md`.

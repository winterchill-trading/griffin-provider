# Mapping: banking-provider to Griffin

How each `Provider.S` and `Sandbox.S` operation is carried out with the Griffin v0 API
(through `griffin-client`), how Griffin's events become `Event.t`, and what has no Griffin
counterpart. Paths are shown with their `/v0` prefix; the client reaches most of them by
the hypermedia links of the index, the organization and each resource.

## Ids

| Ours                     | Griffin                                   | Where the link lives                    |
| ------------------------ | ----------------------------------------- | --------------------------------------- |
| `Customer_ref.t`         | legal person id (`lp.…`)                  | the ref itself                          |
| `Kyc_core.Customer_id.t` | none (Griffin has no external id field)   | `Store.find_customer`                   |
| `Account_ref.t`          | bank account id (`ba.…`)                  | the ref itself; `Store.find_account` per customer and currency, and Griffin lists accounts by owner |
| `Transfer.Id.t`          | payment id (`pm.…`), then submission id (`ps.…`) | `Store.Transfer_record`          |
| deposit `Transfer.Id.t`  | inbound payment id                        | `Event.incoming_transfer_id` of it      |
| `Event_id.t`             | derived from Griffin data (see Events)    | none: poll, webhook and queries derive the same id |

Griffin takes no idempotency keys: creating a legal person, an account or a payment twice
makes two. Every create is made idempotent by looking up the store first, and
`open_account` also lists the legal person's accounts (`filter[owner-url][eq]`) before
opening one. A payment is recorded before it is submitted; submission itself is idempotent
at Griffin (a repeat answers `410 Gone`).

## Operations

| `Provider.S`            | Griffin endpoint(s)                                                      | Notes |
| ----------------------- | ------------------------------------------------------------------------ | ----- |
| `name`                  | none                                                                     | `"griffin"` |
| `create_customer`       | `POST /organizations/{id}/legal-persons` (individual, claims); a known customer: `GET /legal-persons/{id}` | claims from the person plus `Config.questionnaire` |
| `update_customer`       | `POST /legal-persons/{id}/claims`, one per person claim                  | Griffin answers 201 for each (verified live); onboarding checks are not rerun by this call |
| `start_verification`    | `Identity_document`, `Address_proof`: `GET /legal-persons/{id}/verifications`, else `POST` the configured workflow | returns `Hosted` with the verification URL as token; other steps are refused |
| `complete_verification` | none                                                                     | refused: Griffin sends no codes |
| `kyc_status`            | `GET /legal-persons/{id}`, `GET /legal-persons/{id}/verifications`       | publishes the change as events |
| `open_account`          | `GET /organizations/{id}/bank/accounts?filter[owner-url][eq]=…`, `GET /organizations/{id}/bank/products`, `POST /bank/products/{id}/accounts` (owner = the legal person), then `GET /bank/accounts/{id}` until `open` | GBP only; product class `Config.customer_product_class` (`embedded`) for individuals; in the sandbox the opening GBP 1m is moved to the funding account by book transfer (`Config.empty_sandbox_accounts`) |
| `accounts`              | `GET /organizations/{id}/bank/accounts?filter[owner-url][eq]=…` (paged)  | |
| `balance`               | `GET /bank/accounts/{id}`                                                | `posted` = `account-balance`, `available` = `available-balance`, `held` the difference |
| `enrich_account`        | `GET /bank/accounts/{id}`                                                | the sort code and account number as `Address.Uk_account` |
| `statement`             | `GET /bank/accounts/{id}/transactions` (paged, newest first, until one is older than `from`) | opening balance from the transaction before `from` |
| `quote_fee`             | none                                                                     | zero: Griffin invoices fees to the organization |
| `initiate_transfer`     | `GET /bank/accounts/{id}`, `POST /bank/accounts/{id}/payments`, `POST /payments/{id}/submissions` (`fps` or `book-transfer`) | `Faster_payments` submits `fps`, `Intraledger` `book-transfer`, other rails are refused; never a challenge; a `422` refusal marks the transfer `Failed` |
| `transfer`              | `GET /submissions/{id}`                                                  | the raw body is read too, for `submission-status-reason` |
| `cancel_transfer`       | none                                                                     | only a payment never submitted (it moves nothing) |
| `verify_payee`          | `POST /organizations/{id}/cop-request` for the beneficiary's sort code and account number | a simulated answer (below) is returned as fixed; other destinations `Not_possible` |
| `confirm_sca`           | none                                                                     | refused: Griffin raises no challenges |
| `quote_swap`, `execute_swap` | none                                                                | refused |
| `issue_virtual_card`, `card`, `cards`, `set_card_status`, `set_card_limits`, `card_details_token` | none | refused: no cards |
| `create_standing_order`, `cancel_standing_order` | none                                            | refused: schedule payments in the application |
| `events`                | polling `GET /organizations/{id}/events?sort=created-at&filter[created-at][gte]=…`, and `kyc_status` of customers not yet decided | only while subscribed |
| `ingest_webhook`        | `GET /security/public-keys` (cached; refetched for an unknown `keyid`)   | RFC 9421 ES512 signature over method, path, host, date, content headers and digest |

| `Sandbox.S`                 | Griffin endpoint(s)                                                  | Notes |
| --------------------------- | -------------------------------------------------------------------- | ----- |
| `simulate_deposit`          | the funding account (`Config.funding_account`, else the largest open operational account, else a new one): `POST …/payments`, `POST …/submissions`; then the target's `GET …/payments?filter[payment-direction][eq]=inbound-payment` and `GET …/admissions` | found again by its reference; `Intraledger` sends a book transfer, other rails Faster Payments |
| `simulate_kyc_decision`     | the verification (started if needed) until its checks finish, then `POST /legal-persons/{id}/decisions` unless the sandbox already decided the same | `Approve` accepted, `Reject` declined with the reason as notes; `Request_resubmission` refused |
| `simulate_payee_check`      | none                                                                 | the answer is kept per beneficiary and returned by later `verify_payee` calls; Griffin's simulator answers one request at a time and words close matches itself |
| `simulate_card_auth`        | none                                                                 | refused |
| `simulate_transfer_outcome` | none                                                                 | refused: the sandbox delivers every payment |
| `ping`                      | with `Config.ping_via_webhook_test`: `POST /webhooks/{id}/actions/test`; otherwise none | by default the `Ping` is published locally (see Gaps) |

Every `Sandbox.S` call refuses to run against an organization whose mode is not
`test-mode`.

Griffin-specific: `uk_details` (`GET /bank/accounts/{id}`), `confirm_payee`
(`POST /organizations/{id}/cop-request`), `simulate_confirm_payee`
(`POST /simulation/organizations/{id}/cop-request/simulate/{outcome}`).

## Account details

Griffin accounts have a sort code and an account number and no IBAN; they are reported as
the account's one `Account.Address.Uk_account` once open, and `uk_details` returns them
directly.

## Payments

| Transfer rail     | Beneficiary destination                                       | Griffin creditor       | Scheme          |
| ----------------- | ------------------------------------------------------------- | ---------------------- | --------------- |
| `Faster_payments` | `Uk_account`, a GB IBAN, or `Internal` text `04-00-04 12345678` | `uk-domestic`         | `fps`           |
| `Intraledger`     | `Internal` with a Griffin account id (`ba.…`)                 | `griffin-bank-account` | `book-transfer` |
| `Chaps`, `Bacs`, SEPA, US, crypto, cards | any                                   | refused                |                 |

Transfers carry `Uk_domestic { scheme_ref; value_date = None }` details, `scheme_ref`
being the submission's end-to-end id; book transfers carry `Intraledger`. Deposits are
reported on the admission's scheme: `fps` as `Faster_payments`, `chaps` and `bacs` on their
rails, `book-transfer` as `Intraledger`. The store keeps each transfer's rail in its V2
form (`Rail.Stable.V2`). References are cut to Griffin's 35 characters.

## Events

Griffin event to `Event.Kind.t`. Event payloads are the resource itself.

| Griffin                                          | Event                                         | Event id |
| ------------------------------------------------ | --------------------------------------------- | -------- |
| `verification-created`, `verification-updated`, `decision-created` (and each `kyc_status`) | `Kyc_step` per changed step, then `Kyc` transitions | `kyc:<lp>:step:<Step>:<State>`, `kyc:<lp>:<From>:<Transition>` |
| `submission-created`, `submission-updated` for a payment in the store | `Transfer` with the update below | `sub:<submission id>:<status>` |
| submission `scheduled`                           | `Submitted`                                   | |
| submission `processing`                          | `Pending`                                     | |
| submission `delivered`                           | `Settled`                                     | |
| submission `failed` with reason `insufficient-funds` | `Failed Insufficient_funds`               | |
| submission `failed` otherwise                    | `Rejected` (four-character scheme code, else `MS03`) | |
| submission `returned`                            | `Returned` (same rule)                        | |
| refused submission (`422`)                       | `Failed Insufficient_funds` or `Failed (Provider_error <code>)` | `failed:<transfer id>` |
| `cancel_transfer`                                | `Cancelled`                                   | `cancel:<transfer id>` |
| `admission-created`, `admission-updated` `processing` / `delivered` | `Incoming_transfer` (pending / settled), amount and debtor from the inbound payment | `adm:<admission id>:<status>` |
| admission `returned`, `cancelled`                | `Transfer (Returned MS03)`, `Transfer (Rejected MS03)` on the deposit | same |
| `account-status-created`, `account-status-updated` for an account with an owner | `Account_updated` | `acct:<id>:<Status>` |
| account opened by `open_account`                 | `Account_opened`                              | `acct:<id>:opened` |
| `test-event`                                     | `Ping`                                        | `ping:<event id>` |
| Confirmation of Payee with a beneficiary id      | `Payee_check`                                 | `cop:<beneficiary>:<result>` |
| `payment-created`, `transaction-created`, others | nothing                                       | |

## KYC

| kyc-core step                            | Griffin                                              |
| ---------------------------------------- | ---------------------------------------------------- |
| `Identity_document`, `Address_proof`     | the verification's electronic checks on the claims   |
| `Email`, `Mobile`, `Liveness`, `Source_of_funds` | none (stay `Pending`; the e-mail, mobile and sources of funds are claims, not checks) |

| Griffin                                          | `Kyc_core.Status.t`  |
| ------------------------------------------------ | -------------------- |
| no verification                                  | `Created`            |
| a verification, no decision                      | `Verifying`          |
| latest decision `accepted`                       | `Approved`           |
| latest decision `declined`                       | `Rejected` (notes)   |

Verification `pending`/`in-progress` is step `Sent`, `checks-complete` `Verified`,
`checks-declined` and `failed` `Failed`. Since the tier rules want e-mail and mobile
verified for T1, an approved Griffin customer stays at tier `T0`; approval comes from the
decision.

Claims: `individual-identity`, `contact-details` (e-mail), `individual-residence` (UK and
crown dependency addresses split into building number and street, others as address
lines), `mobile-number`, `nationality`, plus `Config.questionnaire` (employment, income,
tax residencies, US citizenship, purposes and sources of funds, cash use, initial deposit,
international payment countries), which the "Individual - Account Owners" workflow
requires and `Kyc_core.Person.t` does not hold.

## Confirmation of Payee

| Griffin `cop-response.result` or error          | `Beneficiary.Payee_check.t` |
| ----------------------------------------------- | --------------------------- |
| `match`                                         | `Match`                     |
| `close-match`                                   | `Close_match` (suggested name) |
| `no-match`                                      | `No_match`                  |
| `400` `account-not-found`                       | `Account_not_found`         |
| `400` with another `account-…` code (not supported, switched) | `Not_possible` |
| `5xx`                                           | `Unavailable`               |
| any other error                                 | the error                   |

## Gaps

- No idempotency keys at Griffin: the store is load-bearing.
- Cards, swaps, standing orders, crypto, SCA, and outgoing CHAPS and Bacs: not offered.
- Sandbox: no simulator for inbound payments from outside (deposits come from another
  sandbox account), every payment is delivered, and the opening GBP 1m is moved away by a
  book transfer that shows on statements.
- `ping` publishes its own `Ping` unless `ping_via_webhook_test` is set, because the
  organization's single webhook may belong to another integration.

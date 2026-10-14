# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## Unreleased

### Added

- GBP payments on payments-core's UK rails: `Faster_payments` (Griffin `fps`) and
  `Intraledger` (book transfers) with `Uk_domestic` details carrying the end-to-end id;
  deposits reported on the admission's scheme. Accounts report their sort code and
  account number as `Account.Address.Uk_account`.
- `verify_payee` (Confirmation of Payee, with `Account_not_found` and `Unavailable`) and
  `simulate_payee_check` with answers fixed per beneficiary.
- `Config.empty_sandbox_accounts`: new sandbox accounts start at zero.
- The live conformance run uses `Conformance.Config.gbp`.

- `Adapter`: banking-provider's `Provider.S` and `Sandbox.S` over griffin-client.
  Customers as legal persons with claims, onboarding checks and decisions in kyc-core
  terms, GBP accounts, balances and statements, Faster Payments and book transfers,
  deposits from a sandbox funding account, and Griffin's event log and webhooks
  normalized into events. Cards, swaps, standing orders, crypto and SCA answer an error.
- Confirmation of Payee (`confirm_payee`, `simulate_confirm_payee`) as
  `Beneficiary.Payee_check.t`, and `uk_details` for an account's sort code and number.
- `Store` with an in-memory implementation and a stable transfer record.
- `Units`, `Refs`, `Kyc_map`,
  `Account_map`, `Tx_map`.
- `griffin-provider` CLI: KYC status, accounts, balance, UK details, statement, CoP,
  events.
- Live runs: banking-provider's conformance suite and a GBP walk, both gated by
  `GRIFFIN_LIVE_TESTS=1`; offline tests against recorded bodies and an in-memory Griffin.

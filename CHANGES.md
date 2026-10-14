# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## Unreleased

### Added

- `Adapter`: banking-provider's `Provider.S` and `Sandbox.S` over griffin-client.
  Customers as legal persons with claims, onboarding checks and decisions in kyc-core
  terms, GBP accounts, balances and statements, Faster Payments and book transfers,
  deposits from a sandbox funding account, and Griffin's event log and webhooks
  normalized into events. Cards, swaps, standing orders, crypto and SCA answer an error.
- Confirmation of Payee (`confirm_payee`, `simulate_confirm_payee`) as
  `Beneficiary.Payee_check.t`, and `uk_details` for an account's sort code and number.
- `Store` with an in-memory implementation and a stable transfer record.
- `Uk_account` (sort codes, account numbers, GB IBANs), `Units`, `Refs`, `Kyc_map`,
  `Account_map`, `Tx_map`.
- `griffin-provider` CLI: KYC status, accounts, balance, UK details, statement, CoP,
  events.
- Live runs: banking-provider's conformance suite and a GBP walk, both gated by
  `GRIFFIN_LIVE_TESTS=1`; offline tests against recorded bodies and an in-memory Griffin.

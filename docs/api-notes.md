# Griffin API notes (adapter level)

What building this adapter taught us about the Griffin API, on top of
[griffin-client's notes](https://github.com/winterchill-trading/griffin-client/blob/main/docs/api-notes.md)
(authentication, signing, pagination, rate limits, webhooks). Sandbox runs on 2026-10-14.

## Onboarding

- A customer is a legal person created with claims. The "Individual - Account Owners"
  workflow needs, besides identity, contact details and residence, claims for employment,
  income, tax residencies, US citizenship, purposes of the account, sources of funds, cash
  use, an initial deposit and international payment countries. `Kyc_core.Person.t` holds
  none of those, so the adapter takes them from `Config.questionnaire`.
- UK residences (GB and the crown dependencies) need `street-name` plus a building number
  or name; other countries take `address-line-1`. A German and a UK synthetic person were
  both onboarded in the sandbox.
- Starting the workflow's verification, its checks completed and the sandbox's own system
  recorded an `accepted` decision within about 5 to 9 seconds of creating the legal
  person. Posting a decision is only needed for a decline (or if the system has not
  decided yet).
- Posting claims again (`POST /legal-persons/{id}/claims`) answers 201 per claim.

## Accounts

- Individuals get accounts of the `embedded` product class (owner type `individual`),
  opened with `owner-url` set to the legal person. The organization's bank account list
  filters by owner (`filter[owner-url][eq]=/v0/legal-persons/lp.…`), which makes opening
  recoverable when a response is lost.
- Embedded sandbox accounts, like operational ones, start with GBP 1,000,000 deposited.
- Accounts have a sort code (`000001` in the sandbox) and an account number, no IBAN.

## Payments

- Payment references are 1 to 35 characters.
- Above GBP 1,000,000 a submission is refused at once with `422`
  `payment-amount-exceeds-scheme-limit`, for book transfers as well as Faster Payments, and
  before the balance is considered.
- Below that limit but above the balance, the submission is accepted (`201`) and then
  `failed` with `submission-status-reason: insufficient-funds`. That field is not in
  griffin-client's `Submission.t`, so the adapter reads it from the raw body or event
  payload.
- Book transfers between two customers' accounts in one organization are delivered and
  credited within seconds, like Faster Payments between sandbox accounts.
- No customer authentication on payments: an organization moves money on its own API key.

## Events

- The organization event log takes `sort=created-at` (oldest first) and
  `filter[created-at][gte]=<ISO time>`, so a poller can resume from the newest
  `created-at` it handled (deduplicating by `event-url`, since several events share a
  millisecond).
- Payloads are the resource: a submission event carries the submission (including its
  status reason), an admission event the admission (amounts are on its payment), a
  decision event the decision with `legal-person-url`, an account status event only
  `account-url` and `account-status`.
- Observed types: `payment-created`, `transaction-created`, `submission-created`,
  `submission-updated`, `admission-created`, `admission-updated`, `verification-created`,
  `verification-updated`, `verification-resource-created`, `decision-created`,
  `account-status-created`, `account-status-updated`.

## Confirmation of Payee

- `account-not-found` (simulated) answers `400` with code `account-not-found`; a bad
  request (an unknown requester legal person) also answers `400`, with title
  "Invalid URL" and no code. The adapter treats only `account-…` codes as the receiving
  bank's answer.
- A real (non-simulated) check of a sandbox account against its holder's name answered
  `match`.

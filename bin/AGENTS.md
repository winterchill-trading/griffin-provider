# AGENTS.md (bin/)

`griffin-provider` CLI over `Adapter`: `kyc`, `accounts`, `balance`, `uk-details`,
`statement`, `cop`, `events`. Read-mostly: only `cop` posts (a Confirmation of Payee
check). Needs `GRIFFIN_API_KEY` in the environment; `-live` is required for a non-sandbox
organization. Run with `dune exec griffin-provider -- <command>`.

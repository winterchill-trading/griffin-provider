(lang dune 3.17)

(name griffin-provider)

(generate_opam_files true)

(license MIT)

(maintainers "winterchill-trading")

(authors "winterchill-trading")

(source
 (github winterchill-trading/griffin-provider))

(package
 (name griffin-provider)
 (synopsis "banking-provider's Provider.S implemented over the Griffin API")
 (description
  "Adapter from the provider-neutral banking-provider interface to griffin-client: legal persons and onboarding checks, GBP accounts with sort codes, Faster Payments and book transfers, Confirmation of Payee, and Griffin events and webhooks normalized into banking-provider events. Cards, swaps and crypto are refused. Sandbox by default.")
 (depends
  (ocaml
   (>= 5.2))
  dune
  core
  core_unix
  async
  async_kernel
  ppx_jane
  yojson
  money
  ledger
  kyc-core
  payments-core
  card-core
  banking-provider
  griffin-client))

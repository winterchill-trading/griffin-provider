(* Onboard a customer on the Griffin sandbox, open a GBP account, check a payee's name and
   pay them by Faster Payments, all through banking-provider's interface.

   set -a; . ./.env; set +a dune exec examples/onboard_and_pay.exe

   Creates a sandbox legal person, an account and a payment. *)

open! Core
open! Async
open Banking_provider
open Payments_core
module Adapter = Griffin_provider.Adapter

let person : Kyc_core.Person.t =
  let open Kyc_core in
  { given_name = Pii.create "Ada"
  ; family_name = Pii.create "Example"
  ; date_of_birth = Pii.create (Date.create_exn ~y:1990 ~m:Jan ~d:15)
  ; nationality = Pii.create (Country.of_string "GB")
  ; residential_address =
      Pii.create
        { Address.line1 = "1 Example Street"
        ; line2 = None
        ; city = "London"
        ; region = None
        ; postal_code = Some "NW1 6XE"
        ; country = Country.of_string "GB"
        }
  ; email = Pii.create "ada@example.com"
  ; mobile = Pii.create "+447700900000"
  }
;;

let main () =
  let open Deferred.Or_error.Let_syntax in
  let%bind t = Adapter.of_env () in
  let customer_id =
    Kyc_core.Customer_id.of_string
      (sprintf "example-%d" (Time_ns.to_int_ns_since_epoch (Time_ns.now ())))
  in
  let%bind customer = Adapter.create_customer t ~customer_id ~person in
  (* The sandbox runs the onboarding checks and records the decision itself. *)
  let%bind () = Adapter.simulate_kyc_decision t customer.id Approve in
  let%bind account = Adapter.open_account t customer.id Money.Currency.gbp in
  let%bind details = Adapter.uk_details t account.id in
  printf !"account %{Account_ref} at %{Payments_core.Uk_account}\n" account.id details;
  let payee = Payments_core.Uk_account.of_string "04-00-04 12345678" |> ok_exn in
  let%bind check =
    Adapter.confirm_payee t ~customer:customer.id ~name:"Example Payee" payee
  in
  printf !"payee check: %{sexp: Beneficiary.Payee_check.t}\n" check;
  let%bind transfer =
    Deferred.return
      (let open Or_error.Let_syntax in
       let%bind beneficiary =
         Beneficiary.create
           ~id:(Beneficiary.Id.of_string "example-payee")
           ~owner:(Customer_ref.to_string customer.id)
           ~name:"Example Payee"
           ~rail:Faster_payments
           ~now:(Time_ns.now ())
           (Payments_core.Uk_account.to_string payee)
       in
       Transfer.draft
         ~id:(Transfer.Id.of_string (Kyc_core.Customer_id.to_string customer_id ^ "-1"))
         ~rail:Faster_payments
         ~account:(Ledger.Account_id.of_string "customer:gbp")
         ~beneficiary
         ~amount:(Money.Amount.of_minor_units_int Money.Currency.gbp 1_000)
         ~reference:"example"
         ~now:(Time_ns.now ())
         ())
  in
  let%bind (_ : Transfer_info.t Sca_challenge.Or_challenge.t) =
    Adapter.initiate_transfer t ~from:account.id transfer
  in
  let%map info = Adapter.transfer t transfer.id in
  printf !"payment %{sexp: Transfer.Status.t}\n" info.status
;;

let () =
  Command_unix.run
    (Command.async_or_error
       ~summary:"onboard, check a payee and pay on the Griffin sandbox"
       (Command.Param.return main))
;;

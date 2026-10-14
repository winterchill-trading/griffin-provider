(* Read-mostly views of the Griffin sandbox through banking-provider's types: what the
   adapter would hand an application. Credentials come from GRIFFIN_* variables. *)

open! Core
open! Async
open Banking_provider
module Adapter = Griffin_provider.Adapter

let connect ~live =
  match%map Adapter.of_env ~live () with
  | Ok t -> t
  | Error e ->
    Core.eprint_s [%sexp (e : Error.t)];
    Stdlib.exit 1
;;

let print_result sexp_of = function
  | Ok v -> print_s (sexp_of v)
  | Error e ->
    Core.eprint_s [%sexp (e : Error.t)];
    Stdlib.exit 1
;;

let live_flag =
  Command.Param.(
    flag "-live" no_arg ~doc:" allow a non-sandbox key and a live organization")
;;

let command ~summary param f =
  Command.async
    ~summary
    (let%map_open.Command live = live_flag
     and args = param in
     fun () ->
       let%bind t = connect ~live in
       f t args)
;;

let customer = Command.Param.(anon ("LEGAL_PERSON_ID" %: string))
let account = Command.Param.(anon ("BANK_ACCOUNT_ID" %: string))

let kyc =
  command ~summary:"KYC status of a legal person in kyc-core terms" customer (fun t id ->
    Adapter.kyc_status t (Customer_ref.of_string id)
    >>| print_result [%sexp_of: Customer.Kyc_status.t])
;;

let accounts =
  command ~summary:"accounts of a legal person" customer (fun t id ->
    Adapter.accounts t (Customer_ref.of_string id)
    >>| print_result [%sexp_of: Account.t list])
;;

let balance =
  command ~summary:"balance of an account" account (fun t id ->
    Adapter.balance t (Account_ref.of_string id)
    >>| print_result [%sexp_of: Account.Balance.t])
;;

let details =
  command ~summary:"sort code and account number of an account" account (fun t id ->
    Adapter.uk_details t (Account_ref.of_string id)
    >>| print_result [%sexp_of: Griffin_provider.Uk_account.t])
;;

let statement =
  command
    ~summary:"statement of an account over the last days"
    Command.Param.(
      both
        account
        (flag "-days" (optional_with_default 7 int) ~doc:"N days back (default 7)"))
    (fun t (id, days) ->
      let until = Time_ns.now () in
      Adapter.statement
        t
        (Account_ref.of_string id)
        ~from:(Time_ns.sub until (Time_ns.Span.of_day (Float.of_int days)))
        ~until
      >>| print_result [%sexp_of: Statement.t])
;;

let cop =
  command
    ~summary:"Confirmation of Payee: does NAME hold the account?"
    Command.Param.(
      both
        customer
        (both
           (flag "-name" (required string) ~doc:"NAME account holder to check")
           (flag
              "-account"
              (required string)
              ~doc:"DETAILS sort code and account number, or a GB IBAN")))
    (fun t (id, (name, details)) ->
      match Griffin_provider.Uk_account.of_string details with
      | Error e -> return (print_result [%sexp_of: unit] (Error e))
      | Ok u ->
        Adapter.confirm_payee t ~customer:(Customer_ref.of_string id) ~name u
        >>| print_result [%sexp_of: Payments_core.Beneficiary.Payee_check.t])
;;

let events =
  command
    ~summary:"print normalized events for a while (polls the event log)"
    Command.Param.(
      flag "-seconds" (optional_with_default 30 int) ~doc:"N how long (default 30)")
    (fun t seconds ->
      let r = Adapter.events t in
      let%bind () =
        Pipe.iter_without_pushback r ~f:(fun e -> print_s [%sexp (e : Event.t)])
        |> Clock_ns.with_timeout (Time_ns.Span.of_int_sec seconds)
        |> Deferred.ignore_m
      in
      Pipe.close_read r;
      List.iter (Adapter.background_errors t) ~f:(fun e ->
        Core.eprint_s [%sexp (e : Error.t)]);
      return ())
;;

let () =
  Command_unix.run
    (Command.group
       ~summary:"banking-provider views of a Griffin organization (sandbox by default)"
       [ "kyc", kyc
       ; "accounts", accounts
       ; "balance", balance
       ; "uk-details", details
       ; "statement", statement
       ; "cop", cop
       ; "events", events
       ])
;;

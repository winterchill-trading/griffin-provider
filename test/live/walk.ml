(* The conformance suite's money scenarios in GBP: what banking-provider's suite checks
   with EUR, SEPA and cards (which Griffin does not offer), checked here with GBP, Faster
   Payments and book transfers, plus Confirmation of Payee. Each step prints one line. *)

open! Core
open! Async
open Banking_provider
open Payments_core
module Adapter = Griffin_provider.Adapter
module Uk_account = Payments_core.Uk_account

let timeout = Time_ns.Span.of_sec 60.
let gbp s = Money.Amount.of_decimal_string Money.Currency.gbp s |> Or_error.ok_exn
let step name = Core.printf "ok    %s\n%!" name

let check cond fmt =
  ksprintf
    (fun msg -> if cond then return (Ok ()) else Deferred.Or_error.error_string msg)
    fmt
;;

let rec poll ~deadline ~what f =
  match%bind f () with
  | Error _ as e -> return e
  | Ok (Some x) -> return (Ok x)
  | Ok None when Time_ns.( > ) (Time_ns.now ()) deadline ->
    Deferred.Or_error.error_s [%message "timed out waiting" what]
  | Ok None ->
    let%bind () = Clock_ns.after (Time_ns.Span.of_sec 1.) in
    poll ~deadline ~what f
;;

let poll ~what f = poll ~deadline:(Time_ns.add (Time_ns.now ()) timeout) ~what f

let await reader ~what f =
  let rec loop () =
    match%bind Pipe.read reader with
    | `Eof -> Deferred.Or_error.error_s [%message "event stream ended" what]
    | `Ok e ->
      (match f e with
       | Some x -> return (Ok x)
       | None -> loop ())
  in
  match%map Clock_ns.with_timeout timeout (loop ()) with
  | `Result r -> r
  | `Timeout -> Or_error.error_s [%message "timed out waiting for event" what]
;;

(* A UK resident; names stay synthetic. *)
let person : Kyc_core.Person.t =
  let open Kyc_core in
  { given_name = Pii.create "Ada"
  ; family_name = Pii.create "Sandbox"
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
  ; email = Pii.create "hello@winterchill.xyz"
  ; mobile = Pii.create "+447700900000"
  }
;;

let approved_customer t ~run_id suffix =
  let open Deferred.Or_error.Let_syntax in
  let customer_id = Kyc_core.Customer_id.of_string (run_id ^ "-" ^ suffix) in
  let%bind customer = Adapter.create_customer t ~customer_id ~person in
  let%bind () = Adapter.simulate_kyc_decision t customer.id Approve in
  let%map (_ : Customer.Kyc_status.t) =
    poll ~what:"KYC approved" (fun () ->
      let%map s = Adapter.kyc_status t customer.id in
      Option.some_if (Kyc_core.Status.equal s.status Approved) s)
  in
  customer
;;

let available t account =
  let open Deferred.Or_error.Let_syntax in
  let%map b = Adapter.balance t account in
  b.available
;;

(* A sort code destination goes by Faster Payments, a Griffin account id by book transfer. *)
let draft ~id ~(account : Account.t) ~destination amount =
  let rail : Rail.t =
    if String.is_prefix destination ~prefix:"ba." then Intraledger else Faster_payments
  in
  Deferred.return
    (let open Or_error.Let_syntax in
     let%bind beneficiary =
       Beneficiary.create
         ~id:(Beneficiary.Id.of_string ("ben-" ^ id))
         ~owner:(Customer_ref.to_string account.customer)
         ~name:"Example Payee"
         ~rail
         ~now:(Time_ns.now ())
         destination
     in
     Transfer.draft
       ~id:(Transfer.Id.of_string id)
       ~rail
       ~account:(Ledger.Account_id.of_string "walk:app")
       ~beneficiary
       ~amount
       ~reference:"walk payment"
       ~now:(Time_ns.now ())
       ())
;;

let finished t id =
  poll ~what:"the transfer to finish" (fun () ->
    let%map.Deferred.Or_error info = Adapter.transfer t id in
    Option.some_if
      (Transfer.Status.is_final info.status || Transfer.Status.equal info.status Settled)
      info)
;;

let walk t ~run_id =
  let open Deferred.Or_error.Let_syntax in
  let events = Adapter.events t in
  let%bind customer = approved_customer t ~run_id "walk" in
  step "customer created, checks run, decision accepted";
  let%bind () =
    Adapter.update_customer
      t
      customer.id
      ~person:{ person with mobile = Kyc_core.Pii.create "+447700900001" }
  in
  step "customer updated (claims posted again)";
  let%bind account = Adapter.open_account t customer.id Money.Currency.gbp in
  let%bind again = Adapter.open_account t customer.id Money.Currency.gbp in
  let%bind () =
    check (Account_ref.equal account.id again.id) "a second open_account opened another"
  in
  let%bind details = Adapter.uk_details t account.id in
  let%bind listed = Adapter.accounts t customer.id in
  let%bind () =
    check
      (List.exists listed ~f:(fun a -> Account_ref.equal a.id account.id))
      "accounts does not list the opened account"
  in
  let%bind start = available t account.id in
  step
    (sprintf
       "GBP account open with a sort code (opening balance %s)"
       (Money.Amount.to_string start));
  (* Deposit by Faster Payments from the organization's funding account. *)
  let deposit = gbp "100.00" in
  let%bind id =
    Adapter.simulate_deposit t ~account:account.id ~rail:Faster_payments deposit
  in
  let%bind () =
    await events ~what:"Incoming_transfer" (fun (e : Event.t) ->
      match e.kind with
      | Incoming_transfer { transfer; amount; settled = true; _ }
        when Transfer.Id.equal transfer id ->
        Option.some_if (Money.Amount.equal amount deposit) ()
      | _ -> None)
  in
  let%bind funded = Deferred.return (Money.Amount.add start deposit) in
  let%bind (_ : Money.Amount.t) =
    poll ~what:"the deposit on the balance" (fun () ->
      let%map a = available t account.id in
      Option.some_if (Money.Amount.equal a funded) a)
  in
  step "deposit by Faster Payments published once and credited";
  (* Payment by Faster Payments to a sort code and account number. *)
  let payment = gbp "30.00" in
  let%bind quote = Adapter.quote_fee t ~from:account.id ~rail:Faster_payments payment in
  let%bind pay =
    draft ~id:(run_id ^ "-pay") ~account ~destination:"04-00-04 12345678" payment
  in
  let%bind started = Adapter.initiate_transfer t ~from:account.id pay in
  let%bind () =
    match started with
    | Done _ -> return ()
    | Challenge _ -> Deferred.Or_error.error_string "Griffin asked for SCA"
  in
  let%bind info = finished t pay.id in
  let%bind () =
    check
      (Transfer.Status.equal info.status Settled)
      !"payment ended %{sexp: Transfer.Status.t}"
      info.status
  in
  let%bind expected = Deferred.return (Money.Amount.sub funded quote.total) in
  let%bind (_ : Money.Amount.t) =
    poll ~what:"the debit" (fun () ->
      let%map a = available t account.id in
      Option.some_if (Money.Amount.equal a expected) a)
  in
  let%bind () =
    await events ~what:"Transfer Settled" (fun (e : Event.t) ->
      match e.kind with
      | Transfer { transfer; update = Settled; _ } when Transfer.Id.equal transfer pay.id
        -> Some ()
      | _ -> None)
  in
  step "payment by Faster Payments settled, debited amount plus fee, event published";
  (* The same transfer again pays once. *)
  let%bind second = Adapter.initiate_transfer t ~from:account.id pay in
  let%bind () =
    match second with
    | Done _ -> return ()
    | Challenge _ -> Deferred.Or_error.error_string "a resent transfer asked for SCA"
  in
  let%bind after_resend = available t account.id in
  let%bind () =
    check
      (Money.Amount.equal after_resend expected)
      !"paid twice? available %{Money.Amount}"
      after_resend
  in
  step "initiating the same transfer twice pays once";
  (* Book transfer to a second customer's account. *)
  let%bind other = approved_customer t ~run_id "walk-b" in
  let%bind other_account = Adapter.open_account t other.id Money.Currency.gbp in
  let%bind other_start = available t other_account.id in
  let book = gbp "5.00" in
  let%bind move =
    draft
      ~id:(run_id ^ "-book")
      ~account
      ~destination:(Account_ref.to_string other_account.id)
      book
  in
  let%bind (_ : Transfer_info.t Sca_challenge.Or_challenge.t) =
    Adapter.initiate_transfer t ~from:account.id move
  in
  let%bind info = finished t move.id in
  let%bind () =
    check
      (Transfer.Status.equal info.status Settled)
      !"book transfer ended %{sexp: Transfer.Status.t}"
      info.status
  in
  let%bind other_expected = Deferred.return (Money.Amount.add other_start book) in
  let%bind (_ : Money.Amount.t) =
    poll ~what:"the book transfer credit" (fun () ->
      let%map a = available t other_account.id in
      Option.some_if (Money.Amount.equal a other_expected) a)
  in
  step "book transfer between two customers settled and credited";
  (* More than the balance. Sandbox accounts start with GBP 1m, and payments above the
     scheme limit are refused for that reason before the balance is looked at, so first
     move all but GBP 50 to the other customer in two book transfers. *)
  let%bind full = available t account.id in
  let%bind keep = Deferred.return (Money.Amount.sub full (gbp "50.00")) in
  let%bind halves = Deferred.return (Money.Amount.split keep ~parts:2) in
  let%bind () =
    Deferred.Or_error.List.iteri ~how:`Sequential halves ~f:(fun i half ->
      let%bind d =
        draft
          ~id:(sprintf "%s-drain-%d" run_id i)
          ~account
          ~destination:(Account_ref.to_string other_account.id)
          half
      in
      let%bind (_ : Transfer_info.t Sca_challenge.Or_challenge.t) =
        Adapter.initiate_transfer t ~from:account.id d
      in
      let%map (_ : Transfer_info.t) = finished t d.id in
      ())
  in
  let%bind before =
    poll ~what:"the drained balance" (fun () ->
      let%map a = available t account.id in
      Option.some_if (Money.Amount.equal a (gbp "50.00")) a)
  in
  let too_much = Money.Amount.scale before 2 in
  let overdraw ~id ~destination ~what =
    let%bind over = draft ~id ~account ~destination too_much in
    let%bind outcome =
      match%bind.Deferred Adapter.initiate_transfer t ~from:account.id over with
      | Error e -> return (sprintf "refused at once: %s" (Error.to_string_mach e))
      | Ok _ ->
        let%bind info = finished t over.id in
        let%map () =
          check
            (not (Transfer.Status.equal info.status Settled))
            "an overdrawing payment settled"
        in
        sprintf !"ended %{sexp: Transfer.Status.t}" info.status
    in
    let%bind resent = Adapter.initiate_transfer t ~from:account.id over in
    let resent =
      match resent with
      | Done info -> Sexp.to_string [%sexp (info.status : Transfer.Status.t)]
      | Challenge _ -> "challenge"
    in
    let%bind after = available t account.id in
    let%map () =
      check
        (Money.Amount.equal after before)
        !"available changed to %{Money.Amount}"
        after
    in
    step
      (sprintf
         "%s above the balance does not leave the account (%s; resent: %s)"
         what
         outcome
         resent)
  in
  let%bind () =
    overdraw
      ~id:(run_id ^ "-over-book")
      ~destination:(Account_ref.to_string other_account.id)
      ~what:"a book transfer"
  in
  let%bind () =
    overdraw
      ~id:(run_id ^ "-over-fps")
      ~destination:"04-00-04 12345678"
      ~what:"a Faster Payment"
  in
  (* Statement over the walk. *)
  let%bind statement =
    Adapter.statement
      t
      account.id
      ~from:(Time_ns.sub (Time_ns.now ()) (Time_ns.Span.of_hr 1.))
      ~until:(Time_ns.add (Time_ns.now ()) (Time_ns.Span.of_min 1.))
  in
  let%bind () = Deferred.return (Statement.check statement) in
  step
    (sprintf
       "statement: %d lines, closing %s"
       (List.length statement.lines)
       (Money.Amount.to_string statement.closing));
  (* Confirmation of Payee through verify_payee: the customer's own account by name, then
     answers fixed per beneficiary with simulate_payee_check. *)
  let show (c : Beneficiary.Payee_check.t) =
    Sexp.to_string [%sexp (c : Beneficiary.Payee_check.t)]
  in
  let beneficiary ~id ~name destination =
    Beneficiary.create
      ~id:(Beneficiary.Id.of_string (run_id ^ "-" ^ id))
      ~owner:(Customer_ref.to_string customer.id)
      ~name
      ~rail:Faster_payments
      ~now:(Time_ns.now ())
      destination
    |> Deferred.return
  in
  let%bind own_payee =
    beneficiary ~id:"own" ~name:"Ada Sandbox" (Uk_account.to_string details)
  in
  let%bind own = Adapter.verify_payee t ~customer:customer.id own_payee in
  let%bind simulated =
    Deferred.Or_error.List.map
      ~how:`Sequential
      [ Beneficiary.Payee_check.Match
      ; Close_match { suggested_name = "" }
      ; No_match
      ; Account_not_found
      ; Not_possible
      ; Unavailable
      ]
      ~f:(fun answer ->
        let%bind b =
          beneficiary
            ~id:
              ("sim-"
               ^ String.lowercase (List.hd_exn (String.split (show answer) ~on:' ')))
            ~name:"Example Payee"
            "04-00-04 12345678"
        in
        let%bind () = Adapter.simulate_payee_check t b.id answer in
        let%map c = Adapter.verify_payee t ~customer:customer.id b in
        show c)
  in
  step
    (sprintf
       "verify_payee: own account %s; simulated %s"
       (show own)
       (String.concat ~sep:", " simulated));
  (* Refusals. *)
  let%bind () =
    match%bind.Deferred
      Adapter.issue_virtual_card
        t
        ~request_id:(run_id ^ "-card")
        customer.id
        ~account:account.id
    with
    | Ok _ -> Deferred.Or_error.error_string "a card was issued"
    | Error _ -> return ()
  in
  let%bind () =
    match%bind.Deferred Adapter.open_account t customer.id Money.Currency.eur with
    | Ok _ -> Deferred.Or_error.error_string "an EUR account was opened"
    | Error _ -> return ()
  in
  step "cards and EUR refused with an error";
  Pipe.close_read events;
  return ()
;;

let run () =
  let run_id =
    sprintf "gw%d" (Time_ns.to_int_ns_since_epoch (Time_ns.now ()) / 1_000_000_000)
  in
  match%bind Adapter.of_env () with
  | Error e ->
    Core.eprint_s [%sexp (e : Error.t)];
    Stdlib.exit 1
  | Ok t ->
    let%map result =
      Monitor.try_with_or_error ~extract_exn:true (fun () -> walk t ~run_id)
      >>| Or_error.join
    in
    List.iter (Adapter.background_errors t) ~f:(fun e ->
      Core.printf "background: %s\n" (Error.to_string_hum e));
    (match result with
     | Ok () -> Core.printf "GBP walk on the Griffin sandbox passed\n%!"
     | Error e ->
       Core.printf "FAIL  %s\n%!" (Error.to_string_hum e);
       Stdlib.exit 1)
;;

let () =
  let live =
    Option.equal String.equal (Sys.getenv "GRIFFIN_LIVE_TESTS") (Some "1")
    && Griffin_client.Config.env_available ()
  in
  if not live
  then
    Core.print_endline
      "griffin-provider GBP walk skipped (set GRIFFIN_API_KEY and GRIFFIN_LIVE_TESTS=1)"
  else
    Command_unix.run
      (Command.async
         ~summary:"GBP walk on the Griffin sandbox"
         (Command.Param.return run))
;;

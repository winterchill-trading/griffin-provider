open! Core
open! Async
open Banking_provider
open Payments_core
module Adapter = Griffin_provider.Adapter

(* The in-memory Griffin keeps sandbox balances as they open. *)
let config =
  { Adapter.Config.default with
    poll_interval = Time_ns.Span.of_ms 10.
  ; empty_sandbox_accounts = false
  }
;;

let setup () =
  let fake = Fake_griffin.create () in
  let%map client = Fake_griffin.connect fake in
  let store = Griffin_provider.Store.memory () in
  fake, store, Adapter.create ~config ~store client
;;

let person : Kyc_core.Person.t =
  let open Kyc_core in
  { given_name = Pii.create "Ada"
  ; family_name = Pii.create "Example"
  ; date_of_birth = Pii.create (Date.create_exn ~y:1990 ~m:Jan ~d:15)
  ; nationality = Pii.create (Country.of_string "GB")
  ; residential_address =
      Pii.create
        { Address.line1 = "10 Example Street"
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

let customer_id = Kyc_core.Customer_id.of_string "c-1"
let gbp s = Money.Amount.of_decimal_string Money.Currency.gbp s |> Or_error.ok_exn

let approved t =
  let%bind customer = Adapter.create_customer t ~customer_id ~person >>| ok_exn in
  let%map () = Adapter.simulate_kyc_decision t customer.id Approve >>| ok_exn in
  customer
;;

let%expect_test "create_customer is idempotent through the store" =
  let%bind fake, _, t = setup () in
  let%bind a = Adapter.create_customer t ~customer_id ~person >>| ok_exn in
  let%bind b = Adapter.create_customer t ~customer_id ~person >>| ok_exn in
  print_s [%sexp (a.id : Customer_ref.t), (Customer_ref.equal a.id b.id : bool)];
  print_s [%sexp (Fake_griffin.count fake ~meth:"POST" ~prefix:"/v0/organizations" : int)];
  [%expect {|
    (lp.fake0001 true)
    1
    |}];
  return ()
;;

let%expect_test "KYC: checks and the decision become kyc-core events" =
  let%bind _, _, t = setup () in
  let events = Adapter.events t in
  let%bind customer = approved t in
  let%bind status = Adapter.kyc_status t customer.id >>| ok_exn in
  print_s [%sexp (status.status : Kyc_core.Status.t)];
  let seen =
    match Pipe.read_now' events with
    | `Ok q -> Queue.to_list q
    | `Eof | `Nothing_available -> []
  in
  Pipe.close_read events;
  List.iter seen ~f:(fun (e : Event.t) -> print_s [%sexp (e.id : Event_id.t)]);
  [%expect
    {|
    Approved
    kyc:lp.fake0001:step:Identity_document:Verified
    kyc:lp.fake0001:step:Address_proof:Verified
    kyc:lp.fake0001:Created:Submit
    kyc:lp.fake0001:Verifying:Approve
    |}];
  let%bind session = Adapter.start_verification t customer.id Email in
  print_s [%sexp (session : Customer.Verification_session.t Or_error.t)];
  [%expect
    {|
    (Error
     ("not offered by Griffin through this adapter" "verification step Email"))
    |}];
  return ()
;;

let%expect_test "open_account opens one GBP account per customer, and finds it again" =
  let%bind fake, _, t = setup () in
  let%bind customer = approved t in
  let%bind a = Adapter.open_account t customer.id Money.Currency.gbp >>| ok_exn in
  let%bind b = Adapter.open_account t customer.id Money.Currency.gbp >>| ok_exn in
  (* A service that lost its store: the account is found by its owner. *)
  let%bind c =
    Adapter.open_account
      (Adapter.create ~config (Adapter.client t))
      customer.id
      Money.Currency.gbp
    >>| ok_exn
  in
  print_s [%sexp (a : Account.t)];
  print_s
    [%sexp
      (Account_ref.equal a.id b.id && Account_ref.equal a.id c.id : bool)
      , (Fake_griffin.count fake ~meth:"POST" ~prefix:"/v0/bank/products" : int)];
  let%bind details = Adapter.uk_details t a.id in
  print_s [%sexp (details : Payments_core.Uk_account.t Or_error.t)];
  let%bind eur = Adapter.open_account t customer.id Money.Currency.eur in
  print_s [%sexp (eur : Account.t Or_error.t)];
  [%expect
    {|
    ((id ba.fake0005) (customer lp.fake0001) (currency GBP) (status Open)
     (addresses
      ((Uk_account
        ((sort_code 000001) (account_number 00000005) (roll_number ())))))
     (opened_at "2026-10-14 09:00:00Z"))
    (true 1)
    (Ok ((sort_code 000001) (account_number 00000005) (roll_number ())))
    (Error ("Griffin holds GBP only" (currency EUR)))
    |}];
  return ()
;;

(* A Griffin account id goes by book transfer, anything else by Faster Payments. *)
let draft ~id ~(account : Account.t) ~destination amount =
  let rail : Rail.t =
    if String.is_prefix destination ~prefix:"ba." then Intraledger else Faster_payments
  in
  let beneficiary =
    Beneficiary.create
      ~id:(Beneficiary.Id.of_string ("ben-" ^ id))
      ~owner:(Customer_ref.to_string account.customer)
      ~name:"Example Payee"
      ~rail
      ~now:Time_ns.epoch
      destination
    |> ok_exn
  in
  Transfer.draft
    ~id:(Transfer.Id.of_string id)
    ~rail
    ~account:(Ledger.Account_id.of_string "app")
    ~beneficiary
    ~amount
    ~reference:"rent"
    ~now:Time_ns.epoch
    ()
  |> ok_exn
;;

let show_started r =
  print_s
    [%sexp
      (Result.map r ~f:(function
         | Sca_challenge.Or_challenge.Done (i : Transfer_info.t) -> i.status
         | Challenge _ -> Draft)
       : Transfer.Status.t Or_error.t)]
;;

let%expect_test "payments: Faster Payments, book transfers, resends and refusals" =
  let%bind fake, store, t = setup () in
  let%bind customer = approved t in
  let%bind account = Adapter.open_account t customer.id Money.Currency.gbp >>| ok_exn in
  Fake_griffin.clear_requests fake;
  let pay = draft ~id:"t-fps" ~account ~destination:"04-00-04 12345678" (gbp "30.00") in
  let%bind started = Adapter.initiate_transfer t ~from:account.id pay in
  show_started started;
  let%bind again = Adapter.initiate_transfer t ~from:account.id pay in
  show_started again;
  print_s [%sexp (Fake_griffin.requests fake : string list)];
  [%expect
    {|
    (Ok Settled)
    (Ok Settled)
    ("GET /v0/bank/accounts/ba.fake0005"
     "POST /v0/bank/accounts/ba.fake0005/payments"
     "POST /v0/payments/pm.fake0006/submissions")
    |}];
  let%bind record = store.find_transfer pay.id in
  (* The record's time is the wall clock's. *)
  let record = Option.map record ~f:(fun r -> { r with updated_at = Time_ns.epoch }) in
  print_s [%sexp (record : Griffin_provider.Store.Transfer_record.t option)];
  [%expect
    {|
    (((id t-fps) (account ba.fake0005) (amount "30.00 GBP")
      (rail Faster_payments) (creditor "04-00-04 12345678") (reference rent)
      (payment_url (/v0/payments/pm.fake0006))
      (submission_url (/v0/submissions/ps.fake0007))
      (scheme_ref (E2EPS.FAKE0007)) (status Settled)
      (updated_at "1970-01-01 00:00:00Z")))
    |}];
  (* A GB IBAN carries the sort code and account number. *)
  let by_iban =
    draft ~id:"t-iban" ~account ~destination:"GB29NWBK60161331926819" (gbp "1.00")
  in
  let book = draft ~id:"t-book" ~account ~destination:"ba.somewhere" (gbp "2.00") in
  Fake_griffin.clear_requests fake;
  let%bind (_ : _ Or_error.t) = Adapter.initiate_transfer t ~from:account.id by_iban in
  let%bind book_started = Adapter.initiate_transfer t ~from:account.id book in
  show_started book_started;
  let%bind iban_record = store.find_transfer by_iban.id in
  let%bind book_record = store.find_transfer book.id in
  print_s
    [%sexp
      (Option.map iban_record ~f:(fun r -> r.rail, r.creditor) : (Rail.t * string) option)
      , (Option.map book_record ~f:(fun r -> r.rail, r.creditor)
         : (Rail.t * string) option)];
  [%expect
    {|
    (Ok Settled)
    (((Faster_payments "60-16-13 31926819")) ((Intraledger ba.somewhere)))
    |}];
  (* Above the scheme limit: refused at once, and a resend does not submit again.
     payments-core's own draft check refuses this amount first, so the record is built
     past it to see Griffin's answer. *)
  let huge =
    { (draft ~id:"t-huge" ~account ~destination:"04-00-04 12345678" (gbp "1.00")) with
      amount = gbp "1000000.01"
    }
  in
  let%bind refused = Adapter.initiate_transfer t ~from:account.id huge in
  print_s [%sexp (Result.is_error refused : bool)];
  Fake_griffin.clear_requests fake;
  let%bind resent = Adapter.initiate_transfer t ~from:account.id huge in
  show_started resent;
  print_s [%sexp (Fake_griffin.requests fake : string list)];
  [%expect
    {|
    true
    (Ok (Failed (Provider_error payment-amount-exceeds-scheme-limit)))
    ()
    |}];
  (* Above the balance: Griffin accepts the submission and fails it. *)
  let%bind balance = Adapter.balance t account.id >>| ok_exn in
  let over =
    draft
      ~id:"t-over"
      ~account
      ~destination:"04-00-04 12345678"
      (Money.Amount.add_exn balance.available (gbp "0.01"))
  in
  let%bind (_ : _ Or_error.t) = Adapter.initiate_transfer t ~from:account.id over in
  let%bind info = Adapter.transfer t over.id in
  print_s [%sexp (Result.map info ~f:(fun i -> i.status) : Transfer.Status.t Or_error.t)];
  [%expect {| (Ok (Failed Insufficient_funds)) |}];
  let%bind cancel = Adapter.cancel_transfer t pay.id in
  print_s [%sexp (Result.is_error cancel : bool)];
  [%expect {| true |}];
  return ()
;;

let%expect_test "webhooks: a signed delivery is verified and mapped, others refused" =
  let%bind _, store, t = setup () in
  let%bind customer = approved t in
  let%bind account = Adapter.open_account t customer.id Money.Currency.gbp >>| ok_exn in
  let pay = draft ~id:"t-hook" ~account ~destination:"04-00-04 12345678" (gbp "5.00") in
  let%bind (_ : _ Or_error.t) = Adapter.initiate_transfer t ~from:account.id pay in
  let%bind record = store.find_transfer pay.id in
  let record = Option.value_exn record in
  let payment_url = Option.value_exn record.payment_url in
  let submission_url = Option.value_exn record.submission_url in
  let event =
    `Assoc
      [ "event-url", `String "/v0/events/ev.hook1"
      ; "event-type", `String "submission-updated"
      ; ( "event-payload"
        , `Assoc
            [ "submission-url", `String submission_url
            ; "submission-status", `String "returned"
            ; "payment-url", `String payment_url
            ; "created-at", `String "2026-10-14T09:00:00.000Z"
            ] )
      ; "created-at", `String "2026-10-14T09:00:00.000Z"
      ]
  in
  let delivery =
    Fake_griffin.signed_delivery
      ~authority:"hooks.example.com"
      ~path:"/webhooks/griffin"
      event
  in
  let%bind got =
    Adapter.ingest_webhook
      t
      { delivery with headers = ("host", "hooks.example.com") :: delivery.headers }
  in
  print_s
    [%sexp
      (Result.map got ~f:(List.map ~f:(fun (e : Event.t) -> e.id, e.kind))
       : (Event_id.t * Event.Kind.t) list Or_error.t)];
  [%expect
    {|
    (Ok
     ((sub:ps.fake0007:returned
       (Transfer (transfer t-hook) (provider_ref pm.fake0006)
        (update (Returned MS03))))))
    |}];
  let%bind tampered =
    Adapter.ingest_webhook
      t
      { headers = ("host", "hooks.example.com") :: delivery.headers
      ; body =
          String.substr_replace_first delivery.body ~pattern:"returned" ~with_:"delivered"
      }
  in
  let%bind elsewhere =
    Adapter.ingest_webhook
      t
      { delivery with headers = ("host", "evil.example.com") :: delivery.headers }
  in
  print_s [%sexp (Result.is_error tampered : bool), (Result.is_error elsewhere : bool)];
  [%expect {| (true true) |}];
  return ()
;;

let%expect_test "what Griffin does not offer answers an error" =
  let%bind _, _, t = setup () in
  let card = Card_core.Ids.Card_id.of_string "card-1" in
  let%bind card_answer = Adapter.card t card in
  let%bind sca =
    Adapter.confirm_sca t (Sca.Id.of_string "x") ~code:(Sensitive.of_string "1")
  in
  let%bind outcome =
    Adapter.simulate_transfer_outcome t (Transfer.Id.of_string "t") Settled
  in
  print_s [%sexp (Result.is_error card_answer : bool)];
  print_s [%sexp (sca : Sca_challenge.Result.t Or_error.t)];
  print_s [%sexp (outcome : unit Or_error.t)];
  [%expect
    {|
    true
    (Error
     ("not offered by Griffin through this adapter"
      "SCA challenges (Griffin raises none)"))
    (Error
     ("not offered by Griffin through this adapter"
      "transfer outcomes (the sandbox delivers every payment)"))
    |}];
  return ()
;;

let%expect_test "a sandbox decline overrides the system's acceptance" =
  let%bind _, _, t = setup () in
  let%bind customer = Adapter.create_customer t ~customer_id ~person >>| ok_exn in
  let%bind () =
    Adapter.simulate_kyc_decision t customer.id (Reject "test decline") >>| ok_exn
  in
  let%bind status = Adapter.kyc_status t customer.id >>| ok_exn in
  print_s [%sexp (status.status : Kyc_core.Status.t)];
  let%bind resubmit =
    Adapter.simulate_kyc_decision t customer.id (Request_resubmission [ Email ])
  in
  print_s [%sexp (Result.is_error resubmit : bool)];
  [%expect {|
    (Rejected "test decline")
    true
    |}];
  return ()
;;

let%expect_test "verify_payee: Confirmation of Payee, and answers fixed per beneficiary" =
  let%bind _, _, t = setup () in
  let%bind customer = approved t in
  let payee id =
    Beneficiary.create
      ~id:(Beneficiary.Id.of_string id)
      ~owner:(Customer_ref.to_string customer.id)
      ~name:"Example Payee"
      ~rail:Faster_payments
      ~now:Time_ns.epoch
      "04-00-04 12345678"
    |> ok_exn
  in
  let events = Adapter.events t in
  let%bind real = Adapter.verify_payee t ~customer:customer.id (payee "b-real") in
  let%bind answers =
    Deferred.List.map
      ~how:`Sequential
      [ Beneficiary.Payee_check.Close_match { suggested_name = "" }
      ; No_match
      ; Account_not_found
      ; Not_possible
      ; Unavailable
      ]
      ~f:(fun answer ->
        let b = payee (Sexp.to_string [%sexp (answer : Beneficiary.Payee_check.t)]) in
        let%bind () = Adapter.simulate_payee_check t b.id answer >>| ok_exn in
        Adapter.verify_payee t ~customer:customer.id b)
  in
  print_s [%sexp (real : Beneficiary.Payee_check.t Or_error.t)];
  List.iter answers ~f:(fun a ->
    print_s [%sexp (a : Beneficiary.Payee_check.t Or_error.t)]);
  let seen =
    match Pipe.read_now' events with
    | `Ok q -> Queue.to_list q
    | `Eof | `Nothing_available -> []
  in
  Pipe.close_read events;
  print_s
    [%sexp
      (List.count seen ~f:(fun (e : Event.t) ->
         match e.kind with
         | Payee_check _ -> true
         | _ -> false)
       : int)];
  [%expect
    {|
    (Ok Match)
    (Ok (Close_match (suggested_name "")))
    (Ok No_match)
    (Ok Account_not_found)
    (Ok Not_possible)
    (Ok Unavailable)
    6
    |}];
  return ()
;;

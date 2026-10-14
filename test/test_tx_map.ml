open! Core
open Griffin_provider
open Banking_provider
module Model = Griffin_client.Model

let submission = Fixture.load "submission" Model.Submission.t_of_yojson

let%expect_test "submission states" =
  List.iter
    [ "scheduled"; "processing"; "delivered"; "failed"; "returned" ]
    ~f:(fun status ->
      let s = { submission with submission_status = status } in
      print_s
        [%sexp
          (status : string)
          , (Tx_map.submission_status s : Payments_core.Transfer.Status.t)
          , (Tx_map.submission_update s : Transfer_update.t)
          , (Tx_map.submission_event_id s : Event_id.t)]);
  [%expect
    {|
    (scheduled Submitted Submitted sub:ps.fixture01xxxxxxxxxxxxx:scheduled)
    (processing Pending Pending sub:ps.fixture01xxxxxxxxxxxxx:processing)
    (delivered Settled Settled sub:ps.fixture01xxxxxxxxxxxxx:delivered)
    (failed (Rejected MS03) (Rejected MS03) sub:ps.fixture01xxxxxxxxxxxxx:failed)
    (returned (Returned MS03) (Returned MS03)
     sub:ps.fixture01xxxxxxxxxxxxx:returned)
    |}];
  print_s
    [%sexp
      (List.map [ None; Some "AC01"; Some "1114"; Some "too long" ] ~f:Tx_map.reason
       : Payments_core.Iso_reason.t list)];
  [%expect {| (MS03 AC01 (Other 1114) MS03) |}]
;;

let admission =
  List.hd_exn (Fixture.items "admissions" ~key:"admissions" Model.Admission.t_of_yojson)
;;

let inbound =
  List.hd_exn (Fixture.items "payments-inbound" ~key:"payments" Model.Payment.t_of_yojson)
;;

let%expect_test "an admitted inbound payment is a deposit" =
  print_s [%sexp (Tx_map.incoming admission inbound : Event.Kind.t option Or_error.t)];
  print_s [%sexp (Tx_map.admission_event_id admission : Event_id.t)];
  [%expect
    {|
    (Ok
     ((Incoming_transfer (account ba.fixture02xxxxxxxxxxxxx)
       (transfer in:pm.fixture03xxxxxxxxxxxxx)
       (provider_ref pm.fixture03xxxxxxxxxxxxx) (rail Intraledger)
       (amount "12.34 GBP") (fee "0.00 GBP")
       (from (External (name "Example Org") (detail "fps 00-00-01 00000000")))
       (reference "fixture inbound") (details Intraledger) (settled true))))
    adm:pa.fixture01xxxxxxxxxxxxx:delivered
    |}];
  let returned = { admission with admission_status = "returned" } in
  print_s [%sexp (Tx_map.incoming returned inbound : Event.Kind.t option Or_error.t)];
  print_s [%sexp (Tx_map.admission_update returned : Transfer_update.t option)];
  [%expect
    {|
    (Ok ())
    ((Returned MS03))
    |}]
;;

let%expect_test "the deposit event gives a transfer the ledger accepts" =
  match Tx_map.incoming admission inbound with
  | Ok (Some kind) ->
    let e = { Event.id = Event_id.of_string "x"; at = Time_ns.epoch; kind } in
    (match Event.incoming_transfer e ~account:(Ledger.Account_id.of_string "cust:gbp") with
     | Some (Ok t) -> print_s [%sexp (t.status : Payments_core.Transfer.Status.t)]
     | Some (Error e) -> print_s [%sexp (e : Error.t)]
     | None -> print_endline "none");
    [%expect {| Settled |}]
  | _ -> assert false
;;

let%expect_test "a submission failed for lack of funds is our failure, not the scheme's" =
  let json =
    Yojson.Safe.from_string
      {|{"submission-url": "/v0/submissions/ps.x", "submission-status": "failed",
         "submission-status-reason": "insufficient-funds", "payment-url": "/v0/payments/pm.x",
         "created-at": "2026-10-14T06:15:54.065Z"}|}
  in
  let s = Griffin_client.Page.decode Model.Submission.t_of_yojson json |> Or_error.ok_exn in
  let status_reason = Tx_map.status_reason json in
  print_s
    [%sexp
      (status_reason : string option)
      , (Tx_map.submission_status ?status_reason s : Payments_core.Transfer.Status.t)
      , (Tx_map.submission_update ?status_reason s : Transfer_update.t)];
  [%expect
    {|
    ((insufficient-funds) (Failed Insufficient_funds)
     (Failed Insufficient_funds))
    |}]
;;

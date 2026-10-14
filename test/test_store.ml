open! Core
open Griffin_provider

let%expect_test "the transfer record's binary shape is pinned" =
  (* A service persists these records; a change here needs a new version and a
     migration. *)
  print_endline [%bin_digest: Store.Transfer_record.t];
  [%expect {| fd7c04e6707ec155d04b7e17ed14628a |}]
;;

let%expect_test "the memory store finds a transfer by its payment" =
  let open Async_kernel in
  let store = Store.memory () in
  let record : Store.Transfer_record.t =
    { id = Payments_core.Transfer.Id.of_string "t-1"
    ; account = Banking_provider.Account_ref.of_string "ba.a"
    ; amount = Money.Amount.of_minor_units_int Money.Currency.gbp 500
    ; scheme = "fps"
    ; creditor = "04-00-04 12345678"
    ; reference = "rent"
    ; payment_url = Some "/v0/payments/pm.p1"
    ; submission_url = None
    ; status = Submitted
    ; updated_at = Time_ns.epoch
    }
  in
  let found = ref None in
  don't_wait_for
    (let%bind () = store.set_transfer record in
     let%map r = store.find_transfer_by_payment "pm.p1" in
     found := Option.map r ~f:(fun r -> r.id));
  Async_kernel_scheduler.Expert.run_cycles_until_no_jobs_remain ();
  print_s [%sexp (!found : Payments_core.Transfer.Id.t option)];
  [%expect {| (t-1) |}]
;;

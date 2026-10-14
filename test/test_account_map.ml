open! Core
open Griffin_provider
open Banking_provider
module Model = Griffin_client.Model

let account = Fixture.load "bank-account" Model.Bank_account.t_of_yojson
let at = Fixture.time "2026-10-13T20:00:00Z"

let%expect_test "a bank account, its UK details and balance" =
  print_s [%sexp (Account_map.account account : Account.t Or_error.t)];
  print_s [%sexp (Account_map.uk_details account : Payments_core.Uk_account.t option)];
  print_s [%sexp (Account_map.balance account ~at : Account.Balance.t Or_error.t)];
  print_s
    [%sexp
      (Account_map.uk_details
         { account with account_status = "opening"; bank_addresses = [] }
       : Payments_core.Uk_account.t option)];
  [%expect
    {|
    (Ok
     ((id ba.fixture01xxxxxxxxxxxxx) (customer lp.fixture01xxxxxxxxxxxxx)
      (currency GBP) (status Open)
      (addresses
       ((Uk_account
         ((sort_code 000001) (account_number 00000000) (roll_number ())))))
      (opened_at "2026-10-13 19:50:49.576Z")))
    (((sort_code 000001) (account_number 00000000) (roll_number ())))
    (Ok
     ((account ba.fixture01xxxxxxxxxxxxx) (available "999982.66 GBP")
      (held "0.00 GBP") (posted "999982.66 GBP") (as_of "2026-10-13 20:00:00Z")))
    ()
    |}]
;;

let txs =
  Fixture.items "transactions" ~key:"account-transactions" Model.Transaction.t_of_yojson
;;

let ref_ = Refs.account ~account_url:account.account_url

let%expect_test "transactions become statement lines" =
  List.iter txs ~f:(fun t ->
    print_s [%sexp (Account_map.line t : Statement.Line.t Or_error.t)]);
  [%expect
    {|
    (Ok
     ((at "2026-10-13 19:51:32.095Z") (amount "-5.00 GBP") (code PAYMENT)
      (reference pm.fixture01xxxxxxxxxxxxx) (balance "999982.66 GBP")))
    (Ok
     ((at "2026-10-13 19:51:08.297Z") (amount "-12.34 GBP") (code PAYMENT)
      (reference pm.fixture02xxxxxxxxxxxxx) (balance "999987.66 GBP")))
    (Ok
     ((at "2026-10-13 19:50:49.892Z") (amount "1000000.00 GBP") (code DEPOSIT)
      (reference tr.fixture03xxxxxxxxxxxxx) (balance "1000000.00 GBP")))
    |}]
;;

let%expect_test "statements take the opening balance from the transaction before" =
  let show from until =
    match
      Account_map.statement ref_ ~from:(Fixture.time from) ~until:(Fixture.time until) txs
    with
    | Error e -> print_s [%sexp (e : Error.t)]
    | Ok s ->
      print_s
        [%sexp
          (s.opening : Money.Amount.t)
          , (List.length s.lines : int)
          , (s.closing : Money.Amount.t)]
  in
  show "2026-10-13T19:00:00Z" "2026-10-13T21:00:00Z";
  show "2026-10-13T19:51:00Z" "2026-10-13T21:00:00Z";
  show "2026-10-13T19:51:10Z" "2026-10-13T19:51:20Z";
  show "2026-10-13T18:00:00Z" "2026-10-13T19:00:00Z";
  [%expect
    {|
    ("0.00 GBP" 3 "999982.66 GBP")
    ("1000000.00 GBP" 2 "999982.66 GBP")
    ("999987.66 GBP" 0 "999987.66 GBP")
    ("0.00 GBP" 0 "0.00 GBP")
    |}]
;;

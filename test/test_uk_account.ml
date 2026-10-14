open! Core
open Griffin_provider

let show s = print_s [%sexp (Uk_account.of_string s : Uk_account.t Or_error.t)]

let%expect_test "sort code and account number, with or without dashes" =
  show "04-00-04 12345678";
  show "040004/12345678";
  show "04000 12345678";
  show "040004 1234567";
  [%expect
    {|
    (Ok ((sort_code 040004) (account_number 12345678)))
    (Ok ((sort_code 040004) (account_number 12345678)))
    (Error ("sort code must be 6 digits" (got 04000)))
    (Error ("account number must be 8 digits" (got 1234567)))
    |}]
;;

let%expect_test "a GB IBAN gives its sort code and account number" =
  (* The example IBAN of the IBAN registry for the United Kingdom. *)
  show "GB29NWBK60161331926819";
  show "GB29 NWBK 6016 1331 9268 19";
  show "DE89370400440532013000";
  [%expect
    {|
    (Ok ((sort_code 601613) (account_number 31926819)))
    (Ok ((sort_code 601613) (account_number 31926819)))
    (Error
     ("expected a GB IBAN or a sort code and account number"
      ("not a UK IBAN" (iban DE89370400440532013000))))
    |}];
  print_endline
    (Uk_account.to_string
       (Uk_account.create ~sort_code:"040004" ~account_number:"12345678"
        |> Or_error.ok_exn));
  [%expect {| 04-00-04 12345678 |}]
;;

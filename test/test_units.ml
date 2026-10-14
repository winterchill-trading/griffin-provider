open! Core
open Griffin_provider

let%expect_test "GBP values convert exactly, other currencies are refused" =
  let show currency value =
    print_s
      [%sexp
        (Units.of_griffin { currency; value } |> Or_error.map ~f:Money.Amount.to_string
         : string Or_error.t)]
  in
  show "GBP" "999982.66";
  show "GBP" "0.10";
  show "EUR" "1.00";
  show "GBP" "1.001";
  [%expect
    {|
    (Ok "999982.66 GBP")
    (Ok "0.10 GBP")
    (Error ("Griffin holds GBP only" (currency EUR)))
    (Error
     ("amount: more fractional digits than the currency has" (input 1.001)))
    |}];
  let value a = print_s [%sexp (Units.to_griffin_value a : string Or_error.t)] in
  value (Money.Amount.of_minor_units_int Money.Currency.gbp 1234);
  value (Money.Amount.of_minor_units_int Money.Currency.gbp 0);
  value (Money.Amount.of_minor_units_int Money.Currency.eur 100);
  [%expect
    {|
    (Ok 12.34)
    (Error ("amount must be positive" (a "0.00 GBP")))
    (Error ("Griffin holds GBP only" (currency EUR)))
    |}]
;;

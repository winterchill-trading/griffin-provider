open! Core

let require_gbp c =
  if Money.Currency.equal c Money.Currency.gbp
  then Ok ()
  else
    Or_error.error_s
      [%message "Griffin holds GBP only" ~currency:(Money.Currency.to_string c : string)]
;;

let of_griffin (m : Griffin_client.Model.Money.t) =
  let open Or_error.Let_syntax in
  let%bind c = Money.Currency.of_string_or_error m.currency in
  let%bind () = require_gbp c in
  Money.Amount.of_decimal_string c m.value
;;

let to_griffin_value a =
  let open Or_error.Let_syntax in
  let%bind () = require_gbp (Money.Amount.currency a) in
  if Money.Amount.is_positive a
  then Ok (Money.Amount.to_decimal_string a)
  else Or_error.error_s [%message "amount must be positive" (a : Money.Amount.t)]
;;

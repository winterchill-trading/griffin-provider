open! Core

type t =
  { sort_code : string
  ; account_number : string
  }
[@@deriving sexp, compare, equal]

let digits ~what ~n s =
  let s = String.filter s ~f:(fun c -> not (Char.equal c '-' || Char.is_whitespace c)) in
  if String.length s = n && String.for_all s ~f:Char.is_digit
  then Ok s
  else Or_error.error_s [%message (sprintf "%s must be %d digits" what n) ~got:s]
;;

let create ~sort_code ~account_number =
  let open Or_error.Let_syntax in
  let%bind sort_code = digits ~what:"sort code" ~n:6 sort_code in
  let%map account_number = digits ~what:"account number" ~n:8 account_number in
  { sort_code; account_number }
;;

let of_iban iban =
  let open Payments_core in
  if not (String.equal (Iban.country iban) "GB")
  then Or_error.error_s [%message "not a UK IBAN" ~iban:(Iban.to_string iban)]
  else (
    (* GB BBAN: four letters of bank code, then the sort code and the account number. *)
    let bban = Iban.bban iban in
    create
      ~sort_code:(String.sub bban ~pos:4 ~len:6)
      ~account_number:(String.sub bban ~pos:10 ~len:8))
;;

let of_string s =
  let s = String.strip s in
  let split =
    match String.lsplit2 s ~on:'/' with
    | Some parts -> Some parts
    | None -> String.rsplit2 s ~on:' '
  in
  let as_pair =
    match split with
    | Some (sort_code, account_number) -> create ~sort_code ~account_number
    | None -> Or_error.error_string "no separator"
  in
  (* An IBAN starts with letters; anything else is meant as a sort code and number. *)
  if Result.is_ok as_pair || not (String.exists s ~f:Char.is_alpha)
  then as_pair
  else
    Or_error.bind (Payments_core.Iban.of_string s) ~f:of_iban
    |> Or_error.tag ~tag:"expected a GB IBAN or a sort code and account number"
;;

let to_string { sort_code; account_number } =
  sprintf
    "%s-%s-%s %s"
    (String.sub sort_code ~pos:0 ~len:2)
    (String.sub sort_code ~pos:2 ~len:2)
    (String.sub sort_code ~pos:4 ~len:2)
    account_number
;;

open! Core
open Banking_provider

let id_of_url url =
  let path = Option.value (List.hd (String.split url ~on:'?')) ~default:url in
  match String.rsplit2 path ~on:'/' with
  | Some (_, id) -> id
  | None -> path
;;

(* Griffin's resource URLs have one shape per collection; building them from the id keeps
   references short and self-contained. *)
let legal_persons = "/v0/legal-persons/"
let accounts = "/v0/bank/accounts/"
let customer ~legal_person_url = Customer_ref.of_string (id_of_url legal_person_url)
let legal_person_url r = legal_persons ^ Customer_ref.to_string r
let account ~account_url = Account_ref.of_string (id_of_url account_url)
let account_url r = accounts ^ Account_ref.to_string r

let check_account r =
  let s = Account_ref.to_string r in
  if String.is_prefix s ~prefix:"ba." && String.length s > 3
  then Ok ()
  else Or_error.error_s [%message "not a Griffin bank account" ~account:s]
;;

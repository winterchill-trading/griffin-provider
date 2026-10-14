(** A UK domestic account: six-digit sort code and eight-digit account number, what
    Faster Payments and Confirmation of Payee address.

    A GB IBAN carries both: after the country and check digits come four letters of bank
    code, the sort code and the account number ([GB29 NWBK 601613 31926819]), so a UK payee
    held as an IBAN converts without any lookup. The other direction needs the bank code,
    which a sort code alone does not give, so no IBAN is invented here. *)

open! Core

type t = private
  { sort_code : string (** six digits, no dashes *)
  ; account_number : string (** eight digits *)
  }
[@@deriving sexp, compare, equal]

(** Accepts dashes and spaces in the sort code ([04-00-04]). *)
val create : sort_code:string -> account_number:string -> t Or_error.t

(** GB IBANs only. *)
val of_iban : Payments_core.Iban.t -> t Or_error.t

(** A GB IBAN, or a sort code and account number separated by a space or slash
    ([04-00-04 12345678], [040004/12345678]). *)
val of_string : string -> t Or_error.t

(** [04-00-04 12345678]. *)
val to_string : t -> string

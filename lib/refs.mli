(** Provider-side ids for Griffin resources.

    Griffin names every resource by a URL such as [/v0/legal-persons/lp.X] or
    [/v0/bank/accounts/ba.Y]; the last segment is the id. A customer reference is the
    legal person id and an account reference the bank account id, so any holder of a
    reference can reach the resource without a lookup table. *)

open! Core
open Banking_provider

(** The last path segment of a resource URL. *)
val id_of_url : string -> string

(** {2 Customers (legal persons)} *)

(** The legal person a URL names. *)
val customer : legal_person_url:string -> Customer_ref.t

(** [/v0/legal-persons/<id>]. *)
val legal_person_url : Customer_ref.t -> string

(** {2 Accounts} *)

(** The bank account a URL names. *)
val account : account_url:string -> Account_ref.t

(** [/v0/bank/accounts/<id>]. *)
val account_url : Account_ref.t -> string

(** Fails on a reference that is not a Griffin bank account id ([ba.] prefix). *)
val check_account : Account_ref.t -> unit Or_error.t

open! Core
open Async_kernel
open Banking_provider
open Payments_core

module Transfer_record = struct
  type t =
    { id : Transfer.Id.Stable.V1.t
    ; account : Account_ref.Stable.V1.t
    ; amount : Money.Amount.Stable.V1.t
    ; scheme : string
    ; creditor : string
    ; reference : string
    ; payment_url : string option
    ; submission_url : string option
    ; status : Transfer.Status.t
    ; updated_at : Utc_time.Stable.V1.t
    }
  [@@deriving bin_io, sexp, compare, equal]
end

type t =
  { find_customer : Kyc_core.Customer_id.t -> Customer_ref.t option Deferred.t
  ; set_customer : Kyc_core.Customer_id.t -> Customer_ref.t -> unit Deferred.t
  ; find_account : Customer_ref.t -> Money.Currency.t -> Account_ref.t option Deferred.t
  ; set_account : Customer_ref.t -> Money.Currency.t -> Account_ref.t -> unit Deferred.t
  ; find_transfer : Transfer.Id.t -> Transfer_record.t option Deferred.t
  ; find_transfer_by_payment : string -> Transfer_record.t option Deferred.t
  ; set_transfer : Transfer_record.t -> unit Deferred.t
  }

let memory () =
  let customers = Hashtbl.create (module Kyc_core.Customer_id) in
  let accounts = Hashtbl.create (module String) in
  let transfers = Hashtbl.create (module Transfer.Id) in
  let by_payment = Hashtbl.create (module String) in
  let account_key c cur =
    Customer_ref.to_string c ^ "/" ^ Money.Currency.to_string cur
  in
  let set tbl key data = Hashtbl.set tbl ~key ~data in
  { find_customer = (fun k -> return (Hashtbl.find customers k))
  ; set_customer = (fun k v -> return (set customers k v))
  ; find_account = (fun c cur -> return (Hashtbl.find accounts (account_key c cur)))
  ; set_account = (fun c cur a -> return (set accounts (account_key c cur) a))
  ; find_transfer = (fun k -> return (Hashtbl.find transfers k))
  ; find_transfer_by_payment =
      (fun p -> return (Option.bind (Hashtbl.find by_payment p) ~f:(Hashtbl.find transfers)))
  ; set_transfer =
      (fun (r : Transfer_record.t) ->
        set transfers r.id r;
        Option.iter r.payment_url ~f:(fun u -> set by_payment (Refs.id_of_url u) r.id);
        return ())
  }
;;

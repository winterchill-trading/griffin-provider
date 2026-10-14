(** What the adapter remembers between calls, in domain types.

    Griffin has no idempotency keys and no field for our ids: creating a legal person, an
    account or a payment twice makes two. The adapter keeps the links itself: our customer
    id to the legal person, a customer's account per currency, our transfer id to the
    Griffin payment and its submission.

    A service persists these in its own database by implementing {!t} (the transfer record
    has a stable binary form); {!memory} serves tests, the CLI and the conformance run, and
    forgets everything when the process exits. Every write is keyed, so repeating one is
    harmless. *)

open! Core
open Async_kernel
open Banking_provider
open Payments_core

module Transfer_record : sig
  (** One outgoing payment. It is written before the payment is submitted, so a crash in
      between leaves a created but unsent payment (which moves nothing) that the next
      [initiate_transfer] with the same id submits. *)
  type t =
    { id : Transfer.Id.Stable.V1.t
    ; account : Account_ref.Stable.V1.t
    ; amount : Money.Amount.Stable.V1.t
    ; scheme : string (** [fps] or [book-transfer] *)
    ; creditor : string (** sort code and account number, or the Griffin account id *)
    ; reference : string
    ; payment_url : string option (** once created *)
    ; submission_url : string option (** once submitted *)
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
  (** by Griffin payment id ([pm.]) *)
  ; set_transfer : Transfer_record.t -> unit Deferred.t
  }

(** Hash tables in this process. *)
val memory : unit -> t

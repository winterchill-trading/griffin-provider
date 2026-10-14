(** Griffin amounts ([{"currency": "GBP", "value": "12.34"}]) as [Money.Amount.t].

    Griffin accounts hold pounds sterling only; values are unsigned decimal strings with
    two places, the direction travelling in a separate field. *)

open! Core

(** Exact; fails on a currency other than GBP or a malformed value. *)
val of_griffin : Griffin_client.Model.Money.t -> Money.Amount.t Or_error.t

(** The decimal string Griffin takes for a payment. Fails unless the amount is a positive
    GBP amount. *)
val to_griffin_value : Money.Amount.t -> string Or_error.t

(** Fails for any currency but GBP, naming the one asked for. *)
val require_gbp : Money.Currency.t -> unit Or_error.t

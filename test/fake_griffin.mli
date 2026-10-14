(** A small in-memory Griffin for driving the adapter without a network: the recorded
    index, organization, workflows and products, plus legal persons, verifications,
    decisions, accounts, payments, submissions and the event log kept in tables. Every
    verification completes its checks at once and every submission is delivered, as in
    the sandbox; a payment above the account balance fails with [insufficient-funds] and
    one above GBP 1m is refused with Griffin's scheme-limit error. *)

open! Core
open! Async

type t

val create : unit -> t

(** A sandbox client connected to [t]. *)
val connect : t -> Griffin_client.Client.t Deferred.t

(** ["POST /v0/..."] for every request so far, oldest first. *)
val requests : t -> string list

val clear_requests : t -> unit

(** Requests matching a method and path prefix. *)
val count : t -> meth:string -> prefix:string -> int

(** A delivery of [event] signed with the test webhook key, for [authority] and [path]. *)
val signed_delivery
  :  authority:string
  -> path:string
  -> Yojson.Safe.t
  -> Banking_provider.Webhook.Request.t

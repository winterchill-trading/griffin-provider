(** A throwaway P-521 key (generated with OpenSSL for griffin-client's tests) standing in
    for Griffin's webhook signing key. Test data only. *)

open! Core

val kid : string

(** Public coordinates, raw bytes. *)
val x : string

val y : string
val b64url : string -> string

(** Headers of a delivery signed the way Griffin signs webhooks, created now. *)
val sign_delivery
  :  authority:string
  -> path:string
  -> body:string
  -> (string * string) list

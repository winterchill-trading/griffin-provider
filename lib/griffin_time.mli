(** Griffin's timestamps: ISO 8601 with a [Z] or an offset, e.g.
    [2026-10-13T19:50:49.576Z]. *)

open! Core

(** [None] when malformed. *)
val parse : string -> Time_ns.t option

(** [parse], or [default] when the field is absent or malformed. *)
val parse_or : default:Time_ns.t -> string option -> Time_ns.t

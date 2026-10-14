(** Recorded, redacted Griffin sandbox bodies in [fixtures/]. *)

open! Core

val json : string -> Yojson.Safe.t

(** Decode [fixtures/<name>.json] with a [t_of_yojson]. *)
val load : string -> (Yojson.Safe.t -> 'a) -> 'a

(** One field of a list body ([{"accounts": [...]}]), decoded. *)
val items : string -> key:string -> (Yojson.Safe.t -> 'a) -> 'a list

val time : string -> Time_ns.t

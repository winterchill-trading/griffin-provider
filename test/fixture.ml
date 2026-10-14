open! Core

let json name = Yojson.Safe.from_file ("fixtures/" ^ name ^ ".json")
let load name f = Griffin_client.Page.decode f (json name) |> Or_error.ok_exn

let items name ~key f =
  (Griffin_client.Page.of_json ~key f (json name) |> Or_error.ok_exn).items
;;

let time s = Time_ns.of_string_with_utc_offset s

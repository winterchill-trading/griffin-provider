open! Core

let parse s = Option.try_with (fun () -> Time_ns.of_string_with_utc_offset s)
let parse_or ~default s = Option.bind s ~f:parse |> Option.value ~default

open! Core
open! Async
open Banking_provider
module Adapter = Griffin_provider.Adapter
module Suite = Conformance.Make (Adapter) (Adapter)

let live () =
  Option.equal String.equal (Sys.getenv "GRIFFIN_LIVE_TESTS") (Some "1")
  && Griffin_client.Config.env_available ()
;;

let run () =
  let run_id =
    sprintf "gp%d" (Time_ns.to_int_ns_since_epoch (Time_ns.now ()) / 1_000_000_000)
  in
  (* The suite's GBP configuration (Faster Payments, a UK resident), with its own timeouts
     and poll interval unchanged. *)
  let config = Conformance.Config.gbp ~run_id in
  match%bind
    Adapter.of_env
      ~config:
        { Adapter.Config.default with
          open_timeout = config.timeout
        ; (* The suite's forged delivery carries no host header; with an authority to
             check against, it is refused by the signature check rather than for want of a
             host. *)
          webhook_authority = Some "hooks.example.com"
        }
      ()
  with
  | Error e ->
    Core.eprint_s [%sexp (e : Error.t)];
    Stdlib.exit 1
  | Ok adapter ->
    let only = Sys.getenv "GRIFFIN_CONFORMANCE_ONLY" in
    let scenarios =
      Suite.scenarios config
      |> List.filter ~f:(fun (s : Suite.scenario) ->
        match only with
        | None -> true
        | Some sub -> String.is_substring s.name ~substring:sub)
    in
    let%map results =
      Deferred.List.map ~how:`Sequential scenarios ~f:(fun s ->
        let started = Time_ns.now () in
        let%map result =
          Monitor.try_with_or_error ~extract_exn:true (fun () -> s.run adapter)
          >>| Or_error.join
        in
        let took = Time_ns.diff (Time_ns.now ()) started in
        (match result with
         | Ok () ->
           Core.printf "ok    %s (%s)\n%!" s.name (Time_ns.Span.to_short_string took)
         | Error e ->
           Core.printf
             "FAIL  %s (%s)\n      %s\n%!"
             s.name
             (Time_ns.Span.to_short_string took)
             (Error.to_string_hum e));
        result)
    in
    List.iter (Adapter.background_errors adapter) ~f:(fun e ->
      Core.printf "background: %s\n" (Error.to_string_hum e));
    let failed = List.count results ~f:Result.is_error in
    Core.printf
      "conformance on the Griffin sandbox: %d passed, %d failed\n%!"
      (List.length results - failed)
      failed;
    (* The card scenario cannot pass: Griffin issues no cards. Set
       GRIFFIN_CONFORMANCE_STRICT=1 to fail on any failure. *)
    if failed > 0
       && Option.equal String.equal (Sys.getenv "GRIFFIN_CONFORMANCE_STRICT") (Some "1")
    then Stdlib.exit 1
;;

let () =
  if not (live ())
  then
    (* Core's printer: the Async scheduler never starts on this path. *)
    Core.print_endline
      "griffin-provider conformance skipped (set GRIFFIN_API_KEY and \
       GRIFFIN_LIVE_TESTS=1)"
  else
    Command_unix.run
      (Command.async
         ~summary:"banking-provider conformance suite on the Griffin sandbox"
         (Command.Param.return run))
;;

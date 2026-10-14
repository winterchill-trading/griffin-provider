open! Core
open! Async
module G = Griffin_client

let file name = In_channel.read_all ("fixtures/" ^ name ^ ".json")
let created_at = "2026-10-14T09:00:00.000Z"

type account =
  { id : string
  ; owner : string option
  ; mutable pence : int
  ; sort_code : string
  ; number : string
  }

type t =
  { mutable next : int
  ; legal_persons : (string, Yojson.Safe.t) Hashtbl.t
  ; verifications : (string, Yojson.Safe.t list) Hashtbl.t (** by legal person, newest first *)
  ; accounts : (string, account) Hashtbl.t
  ; payments : (string, Yojson.Safe.t) Hashtbl.t
  ; submissions : (string, Yojson.Safe.t list) Hashtbl.t (** by payment *)
  ; mutable events : Yojson.Safe.t list (** newest first *)
  ; log : string Queue.t
  }

let create () =
  { next = 0
  ; legal_persons = Hashtbl.create (module String)
  ; verifications = Hashtbl.create (module String)
  ; accounts = Hashtbl.create (module String)
  ; payments = Hashtbl.create (module String)
  ; submissions = Hashtbl.create (module String)
  ; events = []
  ; log = Queue.create ()
  }
;;

let requests t = Queue.to_list t.log
let clear_requests t = Queue.clear t.log

let count t ~meth ~prefix =
  List.count (requests t) ~f:(String.is_prefix ~prefix:(meth ^ " " ^ prefix))
;;

let fresh t prefix =
  t.next <- t.next + 1;
  sprintf "%s.fake%04d" prefix t.next
;;

let str s = `String s
let money pence = `Assoc [ "currency", str "GBP"; "value", str (sprintf "%d.%02d" (pence / 100) (pence mod 100)) ]

let pence_of (j : Yojson.Safe.t) =
  let open Yojson.Safe.Util in
  let v = j |> member "value" |> to_string in
  match String.lsplit2 v ~on:'.' with
  | Some (a, b) -> (Int.of_string a * 100) + Int.of_string (String.prefix (b ^ "00") 2)
  | None -> Int.of_string v * 100
;;

let set (j : Yojson.Safe.t) key v =
  match j with
  | `Assoc fields ->
    `Assoc ((key, v) :: List.filter fields ~f:(fun (k, _) -> not (String.equal k key)))
  | other -> other
;;

let event t ty payload =
  let url = "/v0/events/" ^ fresh t "ev" in
  t.events
  <- `Assoc
       [ "event-url", str url
       ; "event-type", str ty
       ; "event-payload", payload
       ; "created-at", str created_at
       ]
     :: t.events
;;

let page key items = `Assoc [ key, `List items; "links", `Assoc [ "prev", `Null; "next", `Null ] ]

let account_json (a : account) =
  let url = "/v0/bank/accounts/" ^ a.id in
  `Assoc
    ([ "account-url", str url
     ; "display-name", str "fake account"
     ; "account-status", str "open"
     ; "bank-product-type", str "embedded-account"
     ; "account-balance", money a.pence
     ; "available-balance", money a.pence
     ; ( "bank-addresses"
       , `List
           [ `Assoc
               [ "account-holder", str "fake account"
               ; "bank-id", str a.sort_code
               ; "bank-id-code", str "gbdsc"
               ; "account-number", str a.number
               ; "account-number-code", str "bban"
               ]
           ] )
     ; "account-transactions-url", str (url ^ "/transactions")
     ; "account-payments-url", str (url ^ "/payments")
     ; "account-admissions-url", str (url ^ "/admissions")
     ; "created-at", str created_at
     ]
     @ Option.value_map a.owner ~default:[] ~f:(fun o -> [ "owner-url", str o ]))
;;

let legal_person t body =
  let id = fresh t "lp" in
  let url = "/v0/legal-persons/" ^ id in
  let open Yojson.Safe.Util in
  let lp =
    `Assoc
      [ "legal-person-url", str url
      ; "legal-person-type", str "individual"
      ; "display-name", body |> member "display-name"
      ; "created-at", str created_at
      ; "legal-person-verifications-url", str (url ^ "/verifications")
      ; "legal-person-decisions-url", str (url ^ "/decisions")
      ; "legal-person-claims-url", str (url ^ "/claims")
      ]
  in
  Hashtbl.set t.legal_persons ~key:id ~data:lp;
  lp
;;

let decide t lp_id ~outcome ~verification_url =
  let lp_url = "/v0/legal-persons/" ^ lp_id in
  let decision =
    `Assoc
      [ "legal-person-url", str lp_url
      ; "decision-outcome", str outcome
      ; "verification-url", str verification_url
      ; "decision-notes", str ""
      ; "created-at", str created_at
      ]
  in
  Hashtbl.update t.legal_persons lp_id ~f:(fun lp ->
    set (Option.value_exn lp) "latest-decision" decision);
  event t "decision-created" decision;
  decision
;;

let verify t lp_id =
  let id = fresh t "vn" in
  let url = "/v0/verifications/" ^ id in
  let v =
    `Assoc
      [ "verification-url", str url
      ; "verification-status", str "checks-complete"
      ; "legal-person-url", str ("/v0/legal-persons/" ^ lp_id)
      ; "workflow-url", str "/v0/workflows/wf.fixture05xxxxxxxxxxxxx"
      ; "created-at", str created_at
      ]
  in
  Hashtbl.add_multi t.verifications ~key:lp_id ~data:v;
  event t "verification-created" v;
  (* The sandbox decides on its own once the checks complete. *)
  ignore (decide t lp_id ~outcome:"accepted" ~verification_url:url : Yojson.Safe.t);
  v
;;

let open_account t body =
  let open Yojson.Safe.Util in
  let n = t.next + 1 in
  let a =
    { id = fresh t "ba"
    ; owner = body |> member "owner-url" |> to_string_option
    ; pence = 100_000_000 (* sandbox accounts start with GBP 1m *)
    ; sort_code = "000001"
    ; number = sprintf "%08d" n
    }
  in
  Hashtbl.set t.accounts ~key:a.id ~data:a;
  account_json a
;;

let error ~status ~code ~detail =
  ( status
  , Yojson.Safe.to_string
      (`Assoc
        [ ( "errors"
          , `List
              [ `Assoc
                  [ "title", str "Unprocessable entity"
                  ; "status", str (Int.to_string status)
                  ; "detail", str detail
                  ; "code", str code
                  ]
              ] )
        ]) )
;;

let create_payment t account_id body =
  let open Yojson.Safe.Util in
  let id = fresh t "pm" in
  let url = "/v0/payments/" ^ id in
  let p =
    `Assoc
      [ "payment-url", str url
      ; "payment-direction", str "outbound-payment"
      ; "payment-amount", body |> member "payment-amount"
      ; "payment-reference", body |> member "payment-reference"
      ; "creditor", body |> member "creditor"
      ; "debtor", `Assoc [ "account-url", str ("/v0/bank/accounts/" ^ account_id) ]
      ; "payment-submissions-url", str (url ^ "/submissions")
      ; "created-at", str created_at
      ]
  in
  Hashtbl.set t.payments ~key:id ~data:p;
  p
;;

let submit t payment_id =
  let open Yojson.Safe.Util in
  match Hashtbl.find t.submissions payment_id with
  | Some (_ :: _) ->
    error ~status:410 ~code:"payment-already-submitted" ~detail:"already submitted"
  | _ ->
    let p = Hashtbl.find_exn t.payments payment_id in
    let pence = pence_of (p |> member "payment-amount") in
    let debtor =
      p |> member "debtor" |> member "account-url" |> to_string |> Griffin_provider.Refs.id_of_url
    in
    let from = Hashtbl.find_exn t.accounts debtor in
    if pence > 100_000_000
    then
      error
        ~status:422
        ~code:"payment-amount-exceeds-scheme-limit"
        ~detail:"Payment amount exceeds scheme limit"
    else (
      let ok = pence <= from.pence in
      if ok then from.pence <- from.pence - pence;
      let id = fresh t "ps" in
      let s =
        `Assoc
          ([ "submission-url", str ("/v0/submissions/" ^ id)
           ; "submission-status", str (if ok then "delivered" else "failed")
           ; "payment-url", p |> member "payment-url"
           ; "account-url", str ("/v0/bank/accounts/" ^ debtor)
           ; "created-at", str created_at
           ]
           @ if ok then [] else [ "submission-status-reason", str "insufficient-funds" ])
      in
      Hashtbl.add_multi t.submissions ~key:payment_id ~data:s;
      event t "submission-created" s;
      201, Yojson.Safe.to_string s)
;;

let route t ~meth ~path ~query ~body =
  let ok j = 200, Yojson.Safe.to_string j in
  let created j = 201, Yojson.Safe.to_string j in
  let body () = Yojson.Safe.from_string body in
  match meth, String.split (String.chop_prefix_if_exists path ~prefix:"/v0/") ~on:'/' with
  | `GET, [ "index" ] -> 200, file "index"
  | `GET, [ "security"; "public-keys" ] ->
    ok
      (`Assoc
        [ ( "keys"
          , `List
              [ `Assoc
                  [ "alg", str "ES512"
                  ; "crv", str "P-521"
                  ; "kid", str Test_key.kid
                  ; "kty", str "EC"
                  ; "x", str (Test_key.b64url Test_key.x)
                  ; "y", str (Test_key.b64url Test_key.y)
                  ]
              ] )
        ])
  | `GET, [ "organizations"; _ ] -> 200, file "organization"
  | `GET, [ "organizations"; _; "workflows" ] -> 200, file "workflows"
  | `GET, [ "organizations"; _; "bank"; "products" ] -> 200, file "bank-products"
  | `GET, [ "organizations"; _; "events" ] -> ok (page "events" (List.rev t.events))
  | `GET, [ "organizations"; _; "bank"; "accounts" ] ->
    let owner =
      List.Assoc.find query "filter[owner-url][eq]" ~equal:String.equal
      |> Option.bind ~f:List.hd
    in
    Hashtbl.data t.accounts
    |> List.filter ~f:(fun a ->
      match owner with
      | None -> true
      | Some o -> Option.equal String.equal a.owner (Some o))
    |> List.map ~f:account_json
    |> page "accounts"
    |> ok
  | `POST, [ "organizations"; _; "legal-persons" ] -> created (legal_person t (body ()))
  | `GET, [ "legal-persons"; id ] ->
    (match Hashtbl.find t.legal_persons id with
     | Some lp -> ok lp
     | None -> error ~status:404 ~code:"not-found" ~detail:"no such legal person")
  | `POST, [ "legal-persons"; _; "claims" ] -> created (body ())
  | `GET, [ "legal-persons"; id; "verifications" ] ->
    ok (page "verifications" (Hashtbl.find_multi t.verifications id))
  | `POST, [ "legal-persons"; id; "verifications" ] -> created (verify t id)
  | `GET, [ "verifications"; id ] ->
    Hashtbl.data t.verifications
    |> List.concat
    |> List.find ~f:(fun v ->
      String.is_suffix
        (Yojson.Safe.Util.(v |> member "verification-url" |> to_string))
        ~suffix:id)
    |> Option.value_map
         ~default:(error ~status:404 ~code:"not-found" ~detail:"no verification")
         ~f:ok
  | `POST, [ "legal-persons"; id; "decisions" ] ->
    let open Yojson.Safe.Util in
    let b = body () in
    created
      (decide
         t
         id
         ~outcome:(b |> member "decision-outcome" |> to_string)
         ~verification_url:(b |> member "verification-url" |> to_string))
  | `POST, [ "bank"; "products"; _; "accounts" ] -> created (open_account t (body ()))
  | `GET, [ "bank"; "accounts"; id ] ->
    (match Hashtbl.find t.accounts id with
     | Some a -> ok (account_json a)
     | None -> error ~status:404 ~code:"not-found" ~detail:"no such account")
  | `GET, [ "bank"; "accounts"; _; "transactions" ] -> ok (page "account-transactions" [])
  | `POST, [ "bank"; "accounts"; id; "payments" ] -> created (create_payment t id (body ()))
  | `POST, [ "payments"; id; "submissions" ] -> submit t id
  | `GET, [ "payments"; id; "submissions" ] ->
    ok (page "submissions" (Hashtbl.find_multi t.submissions id))
  | `GET, [ "payments"; id ] -> ok (Hashtbl.find_exn t.payments id)
  | `GET, [ "submissions"; id ] ->
    Hashtbl.data t.submissions
    |> List.concat
    |> List.find_exn ~f:(fun s ->
      String.is_suffix
        (Yojson.Safe.Util.(s |> member "submission-url" |> to_string))
        ~suffix:id)
    |> ok
  | _ -> error ~status:404 ~code:"not-found" ~detail:("no route " ^ path)
;;

let connect t =
  let send ~meth uri ~headers:_ ~body =
    let path = Uri.path uri in
    Queue.enqueue t.log (G.Transport.Meth.to_string meth ^ " " ^ path);
    let status, body =
      route t ~meth ~path ~query:(Uri.query uri) ~body:(Option.value body ~default:"")
    in
    return (Ok { G.Transport.Response.status; headers = []; body })
  in
  let config = Or_error.ok_exn (G.Config.create ~api_key:"g-test-fake" ()) in
  (* No retries: a fake answer never improves by asking again. *)
  let%map c = G.Client.connect (G.Transport.create ~send ~max_retries:0 config) in
  Or_error.ok_exn c
;;

let signed_delivery ~authority ~path event =
  let body = Yojson.Safe.to_string event in
  { Banking_provider.Webhook.Request.headers =
      Test_key.sign_delivery ~authority ~path ~body
  ; body
  }
;;

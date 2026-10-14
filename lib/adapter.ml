open! Core
open Async
open Banking_provider
open Payments_core
module G = Griffin_client
module Model = G.Model
module Client = G.Client
module Transfer_record = Store.Transfer_record

module Config = struct
  type t =
    { poll_interval : Time_ns.Span.t
    ; open_timeout : Time_ns.Span.t
    ; customer_product_class : string
    ; workflow : string
    ; questionnaire : Kyc_core.Customer_id.t -> Yojson.Safe.t list
    ; display_name : Kyc_core.Customer_id.t -> Kyc_core.Person.t -> string
    ; funding_account : string option
    ; webhook_authority : string option
    ; webhook_path : string
    ; ping_via_webhook_test : bool
    ; event_lookback : Time_ns.Span.t
    }

  let default =
    { poll_interval = Time_ns.Span.of_sec 2.
    ; open_timeout = Time_ns.Span.of_min 2.
    ; customer_product_class = "embedded"
    ; workflow = "Individual - Account Owners"
    ; questionnaire = (fun _ -> Kyc_map.sandbox_questionnaire)
    ; display_name = (fun _ person -> Kyc_map.display_name person)
    ; funding_account = None
    ; webhook_authority = None
    ; webhook_path = "/webhooks/griffin"
    ; ping_via_webhook_test = false
    ; event_lookback = Time_ns.Span.of_min 1.
    }
  ;;
end

type t =
  { config : Config.t
  ; client : Client.t
  ; store : Store.t
  ; subscribers : Event.t Pipe.Writer.t Bag.t
  ; published : Event_id.t Hash_set.t
  ; kyc_seen : (string, Customer.Kyc_status.t) Hashtbl.t (** by legal person id *)
  ; events_seen : String.Hash_set.t (** Griffin event URLs already handled *)
  ; mutable event_cursor : string (** [created-at] of the newest event handled *)
  ; mutable keys : G.Webhook.Keys.t option
  ; mutable funding : Model.Bank_account.t option
  ; mutable polling : bool
  ; mutable errors : Error.t list
  }

let client t = t.client
let background_errors t = List.rev t.errors
let name _ = "griffin"
let now () = Time_ns.now ()
let note_error t e = t.errors <- e :: t.errors
let tr t = Client.transport t.client

let is_sandbox t =
  String.equal (Client.organization t.client).organization_mode "test-mode"
;;

(* Griffin's own timestamp shape, which its [created-at] filters compare against. *)
let iso time =
  let date, ofday = Time_ns.to_date_ofday time ~zone:Time_float.Zone.utc in
  sprintf "%sT%sZ" (Date.to_string date) (Time_ns.Ofday.to_millisecond_string ofday)
;;

let create ?(config = Config.default) ?(store = Store.memory ()) client =
  { config
  ; client
  ; store
  ; subscribers = Bag.create ()
  ; published = Hash_set.create (module Event_id)
  ; kyc_seen = Hashtbl.create (module String)
  ; events_seen = String.Hash_set.create ()
  ; event_cursor = iso (Time_ns.sub (now ()) config.event_lookback)
  ; keys = None
  ; funding = None
  ; polling = false
  ; errors = []
  }
;;

let of_env ?config ?store ?live () =
  let open Deferred.Or_error.Let_syntax in
  let%bind c = Deferred.return (G.Config.of_env ?live ()) in
  let%map client = Client.connect (G.Transport.create c) in
  create ?config ?store client
;;

let unsupported what =
  Deferred.Or_error.error_s [%message "not offered by Griffin through this adapter" what]
;;

let sandbox_only t what =
  if is_sandbox t
  then Deferred.Or_error.ok_unit
  else Deferred.Or_error.error_s [%message "sandbox only" what]
;;

let need what = function
  | Some v -> Ok v
  | None -> Or_error.error_s [%message "missing link" what]
;;

let need_d what v = Deferred.return (need what v)

(* Polls [f] until it gives [Some x], within [Config.open_timeout]. *)
let poll_until t ~what f =
  let deadline = Time_ns.add (now ()) t.config.open_timeout in
  let rec loop () =
    match%bind f () with
    | Error _ as e -> return e
    | Ok (Some x) -> return (Ok x)
    | Ok None ->
      if Time_ns.( > ) (now ()) deadline
      then Deferred.Or_error.error_s [%message "timed out waiting" what]
      else (
        let%bind () = Clock_ns.after (Time_ns.Span.of_sec 1.) in
        loop ())
  in
  loop ()
;;

let with_query link query =
  let sep = if String.mem link '?' then "&" else "?" in
  link ^ sep ^ query
;;

(* {2 Events} *)

let publish t (e : Event.t) =
  if not (Hash_set.mem t.published e.id)
  then (
    Hash_set.add t.published e.id;
    Bag.iter t.subscribers ~f:(fun w ->
      if not (Pipe.is_closed w) then Pipe.write_without_pushback w e))
;;

let publish_all t events =
  List.iter events ~f:(publish t);
  events
;;

let event ~id ~at kind = { Event.id = Event_id.of_string id; at; kind }

(* {2 KYC} *)

let legal_person t customer =
  Client.legal_person t.client (Refs.legal_person_url customer)
;;

let verifications t (lp : Model.Legal_person.t) =
  let open Deferred.Or_error.Let_syntax in
  let%bind link =
    need_d "legal-person-verifications-url" lp.legal_person_verifications_url
  in
  let%map page =
    Client.page
      t.client
      (with_query link "sort=-created-at&page[size]=5")
      ~key:"verifications"
      Model.Verification.t_of_yojson
  in
  page.items
;;

let latest_verification t lp = Deferred.Or_error.map (verifications t lp) ~f:List.hd

let observe_kyc t customer lp ~latest_verification =
  let id = Customer_ref.to_string customer in
  let at = now () in
  let previous =
    Hashtbl.find t.kyc_seen id
    |> Option.value ~default:(Customer.Kyc_status.initial customer)
  in
  let current = Kyc_map.kyc_status customer ~previous lp ~latest_verification ~at in
  Hashtbl.set t.kyc_seen ~key:id ~data:current;
  current, publish_all t (Kyc_map.events ~previous ~current ~at)
;;

let fetch_kyc t customer =
  let open Deferred.Or_error.Let_syntax in
  let%bind lp = legal_person t customer in
  let%map latest_verification = latest_verification t lp in
  observe_kyc t customer lp ~latest_verification
;;

let track_customer t customer =
  let id = Customer_ref.to_string customer in
  if not (Hashtbl.mem t.kyc_seen id)
  then Hashtbl.set t.kyc_seen ~key:id ~data:(Customer.Kyc_status.initial customer)
;;

let customer_of (lp : Model.Legal_person.t) ~customer_id =
  { Customer.id = Refs.customer ~legal_person_url:lp.legal_person_url
  ; customer_id
  ; created_at = Griffin_time.parse_or ~default:(now ()) (Some lp.created_at)
  }
;;

let create_customer t ~customer_id ~person =
  let open Deferred.Or_error.Let_syntax in
  match%bind.Deferred t.store.find_customer customer_id with
  | Some customer ->
    let%map lp = legal_person t customer in
    customer_of lp ~customer_id
  | None ->
    let body =
      G.Claims.legal_person
        ~display_name:(t.config.display_name customer_id person)
        ~legal_person_type:`Individual
        ~claims:(Kyc_map.person_claims person @ t.config.questionnaire customer_id)
    in
    let%bind lp = Client.create_legal_person t.client body in
    let customer = customer_of lp ~customer_id in
    let%bind.Deferred () = t.store.set_customer customer_id customer.id in
    track_customer t customer.id;
    return customer
;;

let update_customer t customer ~person =
  let open Deferred.Or_error.Let_syntax in
  let%bind lp = legal_person t customer in
  let%bind link = need_d "legal-person-claims-url" lp.legal_person_claims_url in
  (* Posting a claim of a type the legal person already has replaces it. *)
  Deferred.Or_error.List.iter
    ~how:`Sequential
    (Kyc_map.person_claims person)
    ~f:(fun claim ->
      let%map (_ : Yojson.Safe.t) = G.Transport.json (tr t) `POST link ~body:claim () in
      ())
;;

let workflow_url t =
  let open Deferred.Or_error.Let_syntax in
  let%bind workflows = Client.workflows t.client in
  List.find workflows ~f:(fun w -> String.equal w.display_name t.config.workflow)
  |> Option.map ~f:(fun w -> w.workflow_url)
  |> Result.of_option
       ~error:(Error.create_s [%message "no such workflow" t.config.workflow])
  |> Deferred.return
;;

let running_or_done (v : Model.Verification.t) =
  not (String.equal v.verification_status "failed")
;;

(* The latest verification, or a new one when there is none or the last one failed. *)
let ensure_verification t (lp : Model.Legal_person.t) =
  let open Deferred.Or_error.Let_syntax in
  match%bind latest_verification t lp with
  | Some v when running_or_done v -> return v
  | _ ->
    let%bind workflow_url = workflow_url t in
    Client.start_verification t.client lp ~workflow_url
;;

let start_verification t customer (step : Kyc_core.Verification.Step.t) =
  let open Deferred.Or_error.Let_syntax in
  match step with
  | Identity_document | Address_proof ->
    let%bind lp = legal_person t customer in
    let%bind v = ensure_verification t lp in
    track_customer t customer;
    let%map (_ : Customer.Kyc_status.t * Event.t list) = fetch_kyc t customer in
    (* Griffin checks the claims electronically; there is no hosted flow for the customer,
       and the result arrives as an event. The token names the verification. *)
    Customer.Verification_session.Hosted
      { step
      ; token = Sensitive.of_string v.verification_url
      ; expires_at = Time_ns.add (now ()) Time_ns.Span.day
      }
  | Email | Mobile | Liveness | Source_of_funds ->
    unsupported
      (sprintf
         "verification step %s"
         (Sexp.to_string [%sexp (step : Kyc_core.Verification.Step.t)]))
;;

let complete_verification _ _ step ~code:_ =
  unsupported
    (sprintf
       "verification codes (%s)"
       (Sexp.to_string [%sexp (step : Kyc_core.Verification.Step.t)]))
;;

let kyc_status t customer =
  track_customer t customer;
  Deferred.Or_error.map (fetch_kyc t customer) ~f:fst
;;

(* {2 Accounts} *)

let bank_account t account =
  let open Deferred.Or_error.Let_syntax in
  let%bind () = Deferred.return (Refs.check_account account) in
  Client.bank_account t.client (Refs.account_url account)
;;

let org_accounts t ~query =
  let open Deferred.Or_error.Let_syntax in
  let%bind link =
    need_d
      "organization-bank-accounts-url"
      (Client.organization t.client).organization_bank_accounts_url
  in
  Client.fold
    t.client
    (with_query link (query ^ "&page[size]=200"))
    ~key:"accounts"
    Model.Bank_account.t_of_yojson
    ~init:[]
    ~f:(fun acc a -> a :: acc)
  >>| List.rev
;;

let customer_accounts t customer =
  org_accounts t ~query:("filter[owner-url][eq]=" ^ Refs.legal_person_url customer)
;;

let account_event (a : Account.t) ~kind =
  let id = Account_ref.to_string a.id in
  let status = Sexp.to_string [%sexp (a.status : Ledger.Account_status.t)] in
  match kind with
  | `Opened -> event ~id:(sprintf "acct:%s:opened" id) ~at:a.opened_at (Account_opened a)
  | `Updated ->
    event ~id:(sprintf "acct:%s:%s" id status) ~at:(now ()) (Account_updated a)
;;

let wait_open t (a : Model.Bank_account.t) =
  let tries =
    Int.max 1 (Float.iround_up_exn (Time_ns.Span.to_sec t.config.open_timeout))
  in
  Client.wait_until_open t.client a ~interval:(Time_ns.Span.of_sec 1.) ~tries
;;

let open_account t customer currency =
  let open Deferred.Or_error.Let_syntax in
  let%bind () = Deferred.return (Units.require_gbp currency) in
  let%bind existing =
    match%bind.Deferred t.store.find_account customer currency with
    | Some account -> bank_account t account >>| Option.some
    | None ->
      (* A lost response may have opened one already: Griffin lists accounts by owner. *)
      let%map accounts = customer_accounts t customer in
      List.find accounts ~f:(fun a -> not (String.equal a.account_status "closed"))
  in
  let%bind opened =
    match existing with
    | Some a -> return a
    | None ->
      let%bind lp = legal_person t customer in
      let%bind products = Client.bank_products t.client in
      let%bind product =
        List.find products ~f:(fun p ->
          String.equal p.bank_account_product_class t.config.customer_product_class
          && Option.equal String.equal p.owner_type (Some "individual"))
        |> Result.of_option
             ~error:
               (Error.create_s
                  [%message "no product for individuals" t.config.customer_product_class])
        |> Deferred.return
      in
      Client.open_account
        t.client
        product
        ~owner_url:lp.legal_person_url
        ~display_name:(lp.display_name ^ " GBP")
  in
  let ref_ = Refs.account ~account_url:opened.account_url in
  let%bind.Deferred () = t.store.set_account customer currency ref_ in
  let%bind opened = wait_open t opened in
  let%map account = Deferred.return (Account_map.account opened) in
  publish t (account_event account ~kind:`Opened);
  account
;;

let accounts t customer =
  let open Deferred.Or_error.Let_syntax in
  let%bind accounts = customer_accounts t customer in
  Deferred.return (List.map accounts ~f:Account_map.account |> Or_error.all)
;;

let balance t account =
  let open Deferred.Or_error.Let_syntax in
  let%bind a = bank_account t account in
  Deferred.return (Account_map.balance a ~at:(now ()))
;;

let enrich_account t account =
  let open Deferred.Or_error.Let_syntax in
  let%bind a = bank_account t account in
  Deferred.return (Account_map.account a)
;;

let uk_details t account =
  let open Deferred.Or_error.Let_syntax in
  let%bind a = bank_account t account in
  Account_map.uk_details a
  |> Result.of_option
       ~error:(Error.create_s [%message "account has no sort code yet" a.account_status])
  |> Deferred.return
;;

(* Transactions come newest first; read pages until one is older than [from]. *)
let transactions_since t (a : Model.Bank_account.t) ~from =
  let open Deferred.Or_error.Let_syntax in
  let%bind link = need_d "account-transactions-url" a.account_transactions_url in
  let rec loop link acc ~pages =
    let%bind page =
      Client.page t.client link ~key:"account-transactions" Model.Transaction.t_of_yojson
    in
    let acc = acc @ page.items in
    let reached =
      List.exists page.items ~f:(fun tx ->
        match Account_map.line tx with
        | Ok l -> Time_ns.( < ) l.at from
        | Error _ -> false)
    in
    match page.next with
    | Some next when (not reached) && pages < 100 -> loop next acc ~pages:(pages + 1)
    | _ -> return acc
  in
  loop (Client.with_page_size link 200) [] ~pages:1
;;

let statement t account ~from ~until =
  let open Deferred.Or_error.Let_syntax in
  let%bind a = bank_account t account in
  let%bind txs = transactions_since t a ~from in
  Deferred.return (Account_map.statement account ~from ~until txs)
;;

(* {2 Transfers} *)

let check_rail (rail : Rail.t) =
  match rail with
  | Intraledger | Sepa_credit | Sepa_instant -> Ok ()
  | Onchain _ | Lightning | Card_scheme ->
    Or_error.error_s
      [%message "not offered by Griffin through this adapter" (rail : Rail.t)]
;;

let quote_fee t ~from ~rail amount =
  ignore (t : t);
  Deferred.return
    (let open Or_error.Let_syntax in
     let%bind () = Refs.check_account from in
     let%bind () = check_rail rail in
     let%map () = Units.require_gbp (Money.Amount.currency amount) in
     (* Griffin charges per-payment fees by invoice to the organization, not on the
        customer's account. *)
     { Transfer_info.Fee_quote.rail
     ; amount
     ; fee = Money.Amount.zero Money.Currency.gbp
     ; total = amount
     })
;;

(* Where a transfer goes, as a Griffin creditor and scheme. *)
let creditor_of (transfer : Transfer.t) =
  let open Or_error.Let_syntax in
  let%bind (b : Beneficiary.t) =
    match transfer.counterparty with
    | Beneficiary b -> Ok b
    | External _ -> Or_error.error_string "an outgoing transfer needs a beneficiary"
  in
  let uk u =
    ( Client.Creditor.Uk_domestic
        { account_holder = b.name
        ; account_number = u.Uk_account.account_number
        ; sort_code = u.sort_code
        }
    , `Fps
    , Uk_account.to_string u )
  in
  match b.destination with
  | Bank_account { iban; _ } -> Uk_account.of_iban iban >>| uk
  | Internal { account } when String.is_prefix account ~prefix:"ba." ->
    Ok
      ( Client.Creditor.Griffin_account (Refs.account_url (Account_ref.of_string account))
      , `Book_transfer
      , account )
  | Internal { account } -> Uk_account.of_string account >>| uk
  | Crypto _ | Lightning _ -> Or_error.error_string "Griffin pays UK bank accounts only"
;;

let info_of_record (r : Transfer_record.t) =
  { Transfer_info.transfer = r.id
  ; provider_ref = Option.value_map r.payment_url ~default:"" ~f:Refs.id_of_url
  ; status = r.status
  ; fee = Money.Amount.zero Money.Currency.gbp
  ; details = Intraledger
  ; updated_at = r.updated_at
  }
;;

let transfer_event (r : Transfer_record.t) ~id ~update =
  event
    ~id
    ~at:(now ())
    (Transfer
       { transfer = r.id
       ; provider_ref = Option.value_map r.payment_url ~default:"" ~f:Refs.id_of_url
       ; update
       })
;;

let observe_submission ?status_reason t (r : Transfer_record.t) (s : Model.Submission.t) =
  let status = Tx_map.submission_status ?status_reason s in
  let%map r =
    if Transfer.Status.equal status r.status && Option.is_some r.submission_url
    then return r
    else (
      let r =
        { r with status; submission_url = Some s.submission_url; updated_at = now () }
      in
      let%map () = t.store.set_transfer r in
      r)
  in
  ( r
  , publish_all
      t
      [ transfer_event
          r
          ~id:(Event_id.to_string (Tx_map.submission_event_id s))
          ~update:(Tx_map.submission_update ?status_reason s)
      ] )
;;

let scheme_of_record (r : Transfer_record.t) =
  if String.equal r.scheme (Tx_map.scheme_name `Book_transfer)
  then `Book_transfer
  else `Fps
;;

(* Griffin refuses a submission it will never accept with a 422 and a code; anything else
   (a timeout, a 5xx) may still have been submitted and is left for a retry. *)
let refusal e =
  match G.Api_error.status_of_error e with
  | Some 422 ->
    let text = Error.to_string_hum e in
    if String.is_substring text ~substring:"insufficient"
    then Some Transfer.Failure_reason.Insufficient_funds
    else Some (Provider_error (Tx_map.error_code text))
  | _ -> None
;;

(* Submits the record's payment and records the submission. A refusal marks the transfer
   [Failed] (so a resend answers with that instead of submitting again), publishes it, and
   is returned as the error. *)
let submit t (r : Transfer_record.t) (payment : Model.Payment.t) =
  match%bind Client.submit_payment t.client payment ~scheme:(scheme_of_record r) with
  | Ok (`Submitted s | `Already_submitted (s :: _)) ->
    Deferred.map (observe_submission t r s) ~f:(fun (r, _) -> Ok r)
  | Ok (`Already_submitted []) -> return (Ok r)
  | Error e ->
    (match refusal e with
     | None -> return (Error e)
     | Some reason ->
       let r = { r with status = Failed reason; updated_at = now () } in
       let%map () = t.store.set_transfer r in
       publish
         t
         (transfer_event
            r
            ~id:("failed:" ^ Transfer.Id.to_string r.id)
            ~update:(Failed reason));
       Error e)
;;

let initiate_transfer t ~from (transfer : Transfer.t) =
  let open Deferred.Or_error.Let_syntax in
  let done_ r = Sca_challenge.Or_challenge.Done (info_of_record r) in
  match%bind.Deferred t.store.find_transfer transfer.id with
  | Some ({ submission_url = Some _; _ } as r) -> return (done_ r)
  | Some r when not (Transfer.Status.equal r.status Draft) -> return (done_ r)
  | Some ({ payment_url = Some url; _ } as r) ->
    (* Created before a crash, never submitted: send it now. *)
    let%bind payment = Client.get t.client url Model.Payment.t_of_yojson in
    let%map r = submit t r payment in
    done_ r
  | Some _ | None ->
    let%bind () = Deferred.return (Refs.check_account from) in
    let%bind () =
      match transfer.direction with
      | Out -> return ()
      | In -> Deferred.Or_error.error_string "only outgoing transfers are initiated"
    in
    let%bind () = Deferred.return (check_rail transfer.rail) in
    let%bind value = Deferred.return (Units.to_griffin_value transfer.amount) in
    let%bind creditor, scheme, creditor_text = Deferred.return (creditor_of transfer) in
    let%bind account = bank_account t from in
    let record =
      { Transfer_record.id = transfer.id
      ; account = from
      ; amount = transfer.amount
      ; scheme = Tx_map.scheme_name scheme
      ; creditor = creditor_text
      ; reference = transfer.reference
      ; payment_url = None
      ; submission_url = None
      ; status = Draft
      ; updated_at = now ()
      }
    in
    let%bind.Deferred () = t.store.set_transfer record in
    (* Griffin references are 1 to 35 characters; an empty one is left to Griffin. *)
    let reference =
      match String.strip transfer.reference with
      | "" -> None
      | r -> Some (String.prefix r 35)
    in
    let%bind payment =
      Client.create_payment ?reference t.client account ~creditor ~amount:value
    in
    let record = { record with payment_url = Some payment.payment_url } in
    let%bind.Deferred () = t.store.set_transfer record in
    let%map r = submit t record payment in
    done_ r
;;

let find_record t id =
  match%map t.store.find_transfer id with
  | Some r -> Ok r
  | None -> Or_error.error_s [%message "unknown transfer" (id : Transfer.Id.t)]
;;

let transfer t id =
  let open Deferred.Or_error.Let_syntax in
  let%bind r = find_record t id in
  match r.submission_url with
  | None -> return (info_of_record r)
  | Some url ->
    (* The raw body as well: the failure reason is not in griffin-client's model. *)
    let%bind json = Client.get t.client url Fn.id in
    let%bind s = Deferred.return (G.Page.decode Model.Submission.t_of_yojson json) in
    let status_reason = Tx_map.status_reason json in
    let%map r, _ = observe_submission ?status_reason t r s |> Deferred.ok in
    info_of_record r
;;

let cancel_transfer t id =
  let open Deferred.Or_error.Let_syntax in
  let%bind r = find_record t id in
  match r.submission_url, r.status with
  | None, (Draft | Cancelled) ->
    (* A payment that was never submitted moves nothing; dropping our record of it is the
       cancellation. *)
    let r = { r with status = Cancelled; updated_at = now () } in
    let%map.Deferred () = t.store.set_transfer r in
    publish
      t
      (transfer_event r ~id:("cancel:" ^ Transfer.Id.to_string id) ~update:Cancelled);
    Ok (info_of_record r)
  | _ ->
    Deferred.Or_error.error_s
      [%message "already submitted to the scheme" (id : Transfer.Id.t)]
;;

let confirm_sca _ _ ~code:_ = unsupported "SCA challenges (Griffin raises none)"

(* {2 Not offered} *)

let quote_swap _ ~from:_ ~to_:_ ~sell:_ = unsupported "swaps"
let execute_swap _ _ = unsupported "swaps"
let issue_virtual_card _ ~request_id:_ _ ~account:_ = unsupported "cards"
let card _ _ = unsupported "cards"
let cards _ _ = unsupported "cards"
let set_card_status _ _ _ = unsupported "cards"
let set_card_limits _ _ _ = unsupported "cards"
let card_details_token _ _ = unsupported "cards"
let create_standing_order _ ~from:_ _ = unsupported "standing orders"
let cancel_standing_order _ _ = unsupported "standing orders"

(* {2 Griffin events} *)

let payload_string (e : Model.Event.t) key =
  match e.event_payload with
  | `Assoc fields ->
    (match List.Assoc.find fields key ~equal:String.equal with
     | Some (`String s) -> Some s
     | _ -> None)
  | _ -> None
;;

let decode_payload (e : Model.Event.t) f = G.Page.decode f e.event_payload

let observe_admission t (a : Model.Admission.t) =
  let open Deferred.Or_error.Let_syntax in
  let%bind payment = Client.get t.client a.payment_url Model.Payment.t_of_yojson in
  let%map kind = Deferred.return (Tx_map.incoming a payment) in
  let id = Event_id.to_string (Tx_map.admission_event_id a) in
  match kind, Tx_map.admission_update a with
  | Some kind, _ -> publish_all t [ event ~id ~at:(now ()) kind ]
  | None, Some update ->
    let provider_ref = Refs.id_of_url payment.payment_url in
    publish_all
      t
      [ event
          ~id
          ~at:(now ())
          (Transfer
             { transfer = Event.incoming_transfer_id ~provider_ref; provider_ref; update })
      ]
  | None, None -> []
;;

(* The events one Griffin event gives. Griffin event payloads are the resource itself. *)
let handle_event t (e : Model.Event.t) =
  let open Deferred.Or_error.Let_syntax in
  match e.event_type with
  | "decision-created" | "verification-created" | "verification-updated" ->
    (match payload_string e "legal-person-url" with
     | None -> return []
     | Some url ->
       let customer = Refs.customer ~legal_person_url:url in
       let%map _, events = fetch_kyc t customer in
       events)
  | "submission-created" | "submission-updated" ->
    let%bind s = Deferred.return (decode_payload e Model.Submission.t_of_yojson) in
    (match%bind.Deferred
       t.store.find_transfer_by_payment (Refs.id_of_url s.payment_url)
     with
     | None -> return []
     | Some r ->
       let status_reason = Tx_map.status_reason e.event_payload in
       Deferred.map (observe_submission ?status_reason t r s) ~f:(fun (_, events) ->
         Ok events))
  | "admission-created" | "admission-updated" ->
    let%bind a = Deferred.return (decode_payload e Model.Admission.t_of_yojson) in
    observe_admission t a
  | "account-status-created" | "account-status-updated" ->
    (match payload_string e "account-url" with
     | None -> return []
     | Some url ->
       let%bind a = Client.bank_account t.client url in
       (match Account_map.account a with
        | Ok account -> return (publish_all t [ account_event account ~kind:`Updated ])
        (* Organization accounts without an owner are not customer accounts. *)
        | Error _ -> return []))
  | "test-event" ->
    return
      (publish_all
         t
         [ event ~id:("ping:" ^ Refs.id_of_url e.event_url) ~at:(now ()) Ping ])
  | _ -> return []
;;

let events_page_link t cursor =
  let open Or_error.Let_syntax in
  let%map link =
    need "organization-events-url" (Client.organization t.client).organization_events_url
  in
  with_query
    link
    (sprintf "sort=created-at&filter[created-at][gte]=%s&page[size]=100" cursor)
;;

let poll_events t =
  let open Deferred.Or_error.Let_syntax in
  let%bind first = Deferred.return (events_page_link t t.event_cursor) in
  let rec loop link ~pages =
    let%bind page = Client.page t.client link ~key:"events" Model.Event.t_of_yojson in
    let%bind () =
      Deferred.Or_error.List.iter ~how:`Sequential page.items ~f:(fun e ->
        if Hash_set.mem t.events_seen e.event_url
        then return ()
        else (
          Hash_set.add t.events_seen e.event_url;
          if String.( > ) e.created_at t.event_cursor then t.event_cursor <- e.created_at;
          match%map.Deferred handle_event t e with
          | Ok (_ : Event.t list) -> Ok ()
          | Error err ->
            note_error t (Error.tag err ~tag:e.event_type);
            Ok ()))
    in
    match page.next with
    | Some next when pages < 20 -> loop next ~pages:(pages + 1)
    | _ -> return ()
  in
  loop first ~pages:1
;;

(* Customers whose onboarding is not concluded: their decision may come from Griffin's own
   system without an event this poll sees first. *)
let poll_customers t =
  Hashtbl.to_alist t.kyc_seen
  |> List.filter ~f:(fun (_, (s : Customer.Kyc_status.t)) ->
    match s.status with
    | Created | Verifying | Needs_resubmission _ -> true
    | Approved | Rejected _ | Blocked _ | Closed _ -> false)
  |> Deferred.List.iter ~how:`Sequential ~f:(fun (_, (s : Customer.Kyc_status.t)) ->
    match%map fetch_kyc t s.customer with
    | Ok _ -> ()
    | Error e -> note_error t e)
;;

let rec poll_loop t =
  if Bag.is_empty t.subscribers
  then (
    t.polling <- false;
    return ())
  else (
    let%bind () =
      match%map poll_events t with
      | Ok () -> ()
      | Error e -> note_error t e
    in
    let%bind () = poll_customers t in
    let%bind () = Clock_ns.after t.config.poll_interval in
    poll_loop t)
;;

let events t =
  let r, w = Pipe.create () in
  let elt = Bag.add t.subscribers w in
  don't_wait_for
    (let%map () = Pipe.closed w in
     Bag.remove t.subscribers elt);
  if not t.polling
  then (
    t.polling <- true;
    don't_wait_for (poll_loop t));
  r
;;

let ingest_webhook t (req : Webhook.Request.t) =
  let open Deferred.Or_error.Let_syntax in
  let%bind authority =
    match Webhook.Request.header req "host", t.config.webhook_authority with
    | Some h, _ | None, Some h -> return h
    | None, None ->
      Deferred.Or_error.error_string
        "no host header and no Config.webhook_authority to verify the signature against"
  in
  let path =
    Webhook.Request.header req "x-webhook-path"
    |> Option.value ~default:t.config.webhook_path
  in
  let%bind keys =
    match t.keys with
    | Some k -> return k
    | None ->
      let%map k = G.Webhook.Keys.fetch (tr t) in
      t.keys <- Some k;
      k
  in
  let%bind e, keys =
    G.Webhook.verify_refreshing
      ~now:(now ())
      (tr t)
      keys
      ~meth:"POST"
      ~authority
      ~path
      ~headers:req.headers
      ~body:req.body
      ()
  in
  t.keys <- Some keys;
  Hash_set.add t.events_seen e.event_url;
  handle_event t e
;;

(* {2 Confirmation of Payee} *)

let payee_check (r : Model.Cop_response.t) : Beneficiary.Payee_check.t =
  match r.result with
  | "match" -> Match
  | "close-match" ->
    Close_match { suggested_name = Option.value r.suggested_name ~default:"" }
  | "no-match" -> No_match
  | _ -> Not_possible
;;

let cop_check customer ~name ~business (u : Uk_account.t) =
  { Client.Cop_check.name
  ; account_number = u.account_number
  ; sort_code = u.sort_code
  ; classification = (if business then `Business else `Personal)
  ; secondary_reference = None
  ; requester_legal_person_url = Refs.legal_person_url customer
  }
;;

let cop_result t ?beneficiary result =
  let check =
    match result with
    | Ok (r : Model.Cop_request.t) -> Ok (payee_check r.cop_response)
    | Error e ->
      (* The receiving bank's refusals (account not found, not supported, switched) come
         as a 400 with an [account-...] code. Anything else, such as an unknown requester,
         is a problem with our request, not an answer about the payee. *)
      (match G.Api_error.status_of_error e with
       | Some 400
         when String.is_prefix
                (Tx_map.error_code (Error.to_string_hum e))
                ~prefix:"account-" -> Ok Beneficiary.Payee_check.Not_possible
       | _ -> Error e)
  in
  Result.iter check ~f:(fun result ->
    Option.iter beneficiary ~f:(fun b ->
      publish
        t
        (event
           ~id:
             (sprintf
                "cop:%s:%s"
                (Beneficiary.Id.to_string b)
                (Sexp.to_string [%sexp (result : Beneficiary.Payee_check.t)]))
           ~at:(now ())
           (Payee_check { beneficiary = b; result }))));
  check
;;

let confirm_payee ?beneficiary ?(business = false) t ~customer ~name u =
  let%map result = Client.confirm_payee t.client (cop_check customer ~name ~business u) in
  cop_result t ?beneficiary result
;;

let simulate_confirm_payee t ~customer ~name u ~outcome =
  let open Deferred.Or_error.Let_syntax in
  let%bind () = sandbox_only t "Confirmation of Payee simulation" in
  let%bind.Deferred result =
    Client.simulate_confirm_payee
      t.client
      (cop_check customer ~name ~business:false u)
      ~outcome
  in
  Deferred.return (cop_result t result)
;;

(* {2 Sandbox} *)

let funding_account t =
  let open Deferred.Or_error.Let_syntax in
  match t.funding, t.config.funding_account with
  | Some a, _ -> return a
  | None, Some url ->
    let%map a = Client.bank_account t.client url in
    t.funding <- Some a;
    a
  | None, None ->
    let%bind candidates =
      org_accounts
        t
        ~query:
          "filter[bank-product-type][in][]=operational-account&filter[account-status][in][]=open"
    in
    let value (a : Model.Bank_account.t) =
      Units.of_griffin a.account_balance
      |> Result.ok
      |> Option.value_map ~default:Z.zero ~f:Money.Amount.minor_units
    in
    let%bind a =
      match
        List.max_elt candidates ~compare:(fun a b -> Z.compare (value a) (value b))
      with
      | Some a -> return a
      | None ->
        (* New sandbox operational accounts come funded. *)
        let%bind products = Client.bank_products t.client in
        let%bind product =
          List.find products ~f:(fun p ->
            String.equal p.bank_account_product_class "operational")
          |> Result.of_option ~error:(Error.of_string "no operational product")
          |> Deferred.return
        in
        let%bind a =
          Client.open_account t.client product ~display_name:"griffin-provider funding"
        in
        wait_open t a
    in
    t.funding <- Some a;
    return a
;;

let simulate_deposit t ~account ~rail amount =
  let open Deferred.Or_error.Let_syntax in
  let%bind () = sandbox_only t "simulate_deposit" in
  let%bind () = Deferred.return (check_rail rail) in
  let%bind value = Deferred.return (Units.to_griffin_value amount) in
  let%bind target = bank_account t account in
  let%bind funding = funding_account t in
  let%bind creditor, scheme =
    match rail with
    | Intraledger ->
      return (Client.Creditor.Griffin_account target.account_url, `Book_transfer)
    | _ ->
      let%map u =
        Deferred.return
          (Account_map.uk_details target
           |> Result.of_option ~error:(Error.of_string "target account has no sort code")
          )
      in
      ( Client.Creditor.Uk_domestic
          { account_holder = target.display_name
          ; account_number = u.account_number
          ; sort_code = u.sort_code
          }
      , `Fps )
  in
  (* The sandbox has no inbound simulator: pay from another sandbox account and find the
     inbound payment by its reference. *)
  let reference = "sim " ^ String.prefix (G.Http_signature.uuid_v4 ()) 18 in
  let%bind payment =
    Client.create_payment ~reference t.client funding ~creditor ~amount:value
  in
  let%bind (_ : [ `Submitted of Model.Submission.t | `Already_submitted of _ ]) =
    Client.submit_payment t.client payment ~scheme
  in
  let%bind payments_link = need_d "account-payments-url" target.account_payments_url in
  let%bind inbound =
    poll_until t ~what:"the inbound payment" (fun () ->
      let%map page =
        Client.page
          t.client
          (with_query
             payments_link
             "filter[payment-direction][eq]=inbound-payment&page[size]=50")
          ~key:"payments"
          Model.Payment.t_of_yojson
      in
      List.find page.items ~f:(fun p ->
        Option.equal String.equal p.payment_reference (Some reference)))
  in
  let%bind admission =
    poll_until t ~what:"the admission" (fun () ->
      let%map admissions = Client.admissions t.client target in
      List.find admissions ~f:(fun a -> String.equal a.payment_url inbound.payment_url))
  in
  let%map (_ : Event.t list) = observe_admission t admission in
  Event.incoming_transfer_id ~provider_ref:(Refs.id_of_url inbound.payment_url)
;;

let finished_verification t lp =
  let open Deferred.Or_error.Let_syntax in
  let%bind v = ensure_verification t lp in
  poll_until t ~what:"the verification checks" (fun () ->
    let%map v = Client.verification t.client v.verification_url in
    match v.verification_status with
    | "pending" | "in-progress" -> None
    | _ -> Some v)
;;

let simulate_kyc_decision t customer (decision : Sandbox.Kyc_decision.t) =
  let open Deferred.Or_error.Let_syntax in
  let%bind () = sandbox_only t "simulate_kyc_decision" in
  track_customer t customer;
  let%bind outcome, notes =
    match decision with
    | Approve -> return (`Accepted, "sandbox approval")
    | Reject reason -> return (`Declined, reason)
    | Request_resubmission _ -> unsupported "resubmission requests (decisions are final)"
  in
  let%bind lp = legal_person t customer in
  let%bind v = finished_verification t lp in
  let wanted =
    match outcome with
    | `Accepted -> "accepted"
    | `Declined -> "declined"
  in
  let decided (lp : Model.Legal_person.t) =
    Option.exists lp.latest_decision ~f:(fun d -> String.equal d.decision_outcome wanted)
  in
  let%bind lp = legal_person t customer in
  let%bind () =
    if decided lp
    then return ()
    else (
      match%bind.Deferred
        Client.decide t.client lp ~verification_url:v.verification_url ~outcome ~notes
      with
      | Ok (_ : Model.Decision.t) -> return ()
      | Error e ->
        (* The sandbox's own system may have decided in between. *)
        let%bind lp = legal_person t customer in
        if decided lp then return () else Deferred.return (Error e))
  in
  let%map (_ : Customer.Kyc_status.t * Event.t list) = fetch_kyc t customer in
  ()
;;

let simulate_card_auth _ _ _ = unsupported "cards"

let simulate_transfer_outcome _ _ _ =
  unsupported "transfer outcomes (the sandbox delivers every payment)"
;;

let ping t =
  let open Deferred.Or_error.Let_syntax in
  let%bind () = sandbox_only t "ping" in
  if t.config.ping_via_webhook_test
  then (
    let%bind hooks = Client.webhooks t.client in
    match hooks with
    | [] -> Deferred.Or_error.error_string "the organization has no webhook"
    | hook :: _ ->
      let%map (_ : Yojson.Safe.t) =
        G.Transport.json (tr t) `POST (hook.webhook_url ^ "/actions/test") ()
      in
      ())
  else (
    (* No test delivery: the organization's single webhook may point at another
       integration, so the Ping is published here. *)
    publish t (event ~id:("ping:local:" ^ G.Http_signature.uuid_v4 ()) ~at:(now ()) Ping);
    return ())
;;

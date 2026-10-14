open! Core
open Banking_provider
open Payments_core
module Model = Griffin_client.Model

let rail = Rail.Intraledger

let scheme_name = function
  | `Fps -> "fps"
  | `Book_transfer -> "book-transfer"
;;

let reason code =
  match code with
  | Some c when String.length c = 4 && String.for_all c ~f:Char.is_alphanum ->
    Iso_reason.of_code c |> Result.ok |> Option.value ~default:Iso_reason.MS03
  | _ -> MS03
;;

let scheme_code (s : Model.Submission.t) =
  Option.bind s.submission_scheme_information ~f:(fun i -> i.scheme_status_code)
;;

let status_reason (json : Yojson.Safe.t) =
  match json with
  | `Assoc fields ->
    (match List.Assoc.find fields "submission-status-reason" ~equal:String.equal with
     | Some (`String r) -> Some r
     | _ -> None)
  | _ -> None
;;

let submission_status ?status_reason (s : Model.Submission.t) : Transfer.Status.t =
  match s.submission_status, status_reason with
  | "processing", _ -> Pending
  | "delivered", _ -> Settled
  | "failed", Some "insufficient-funds" -> Failed Insufficient_funds
  | "failed", _ -> Rejected (reason (scheme_code s))
  | "returned", _ -> Returned (reason (scheme_code s))
  | _ -> Submitted
;;

let submission_update ?status_reason (s : Model.Submission.t) : Transfer_update.t =
  match submission_status ?status_reason s with
  | Pending -> Pending
  | Settled -> Settled
  | Failed f -> Failed f
  | Rejected r -> Rejected r
  | Returned r -> Returned r
  | _ -> Submitted
;;

let party_text (p : Model.Party.t) =
  let details =
    match p.bank_id, p.account_number with
    | Some sort_code, Some account_number ->
      (match Uk_account.create ~sort_code ~account_number with
       | Ok u -> Uk_account.to_string u
       | Error _ -> sort_code ^ " " ^ account_number)
    | _ -> Option.value_map p.account_url ~default:"unknown" ~f:Refs.id_of_url
  in
  match p.account_holder with
  | Some holder -> sprintf "%s (%s)" details holder
  | None -> details
;;

let payment_scheme (a : Model.Admission.t) =
  Option.value_map a.admission_scheme_information ~default:"fps" ~f:(fun i ->
    i.payment_scheme)
;;

let incoming (a : Model.Admission.t) (p : Model.Payment.t) =
  let open Or_error.Let_syntax in
  match a.admission_status with
  | "returned" | "cancelled" -> Ok None
  | status ->
    let%bind account_url =
      match a.account_url, p.creditor.account_url with
      | Some u, _ | None, Some u -> Ok u
      | None, None ->
        Or_error.error_s [%message "admission names no account" a.admission_url]
    in
    let%map amount = Units.of_griffin p.payment_amount in
    let provider_ref = Refs.id_of_url p.payment_url in
    let from =
      match p.debtor with
      | Some d ->
        Transfer.Counterparty.External
          { name = Option.value d.account_holder ~default:""
          ; detail =
              sprintf
                "%s %s"
                (payment_scheme a)
                (party_text { d with account_holder = None })
          }
      | None -> External { name = ""; detail = payment_scheme a }
    in
    Some
      (Event.Kind.Incoming_transfer
         { account = Refs.account ~account_url
         ; transfer = Event.incoming_transfer_id ~provider_ref
         ; provider_ref
         ; rail
         ; amount
         ; fee = Money.Amount.zero Money.Currency.gbp
         ; from
         ; reference = Option.value p.payment_reference ~default:""
         ; details = Intraledger
         ; settled = String.equal status "delivered"
         })
;;

let admission_update (a : Model.Admission.t) : Transfer_update.t option =
  match a.admission_status with
  | "returned" -> Some (Returned MS03)
  | "cancelled" -> Some (Rejected MS03)
  | _ -> None
;;

let submission_event_id (s : Model.Submission.t) =
  Event_id.of_string
    (sprintf "sub:%s:%s" (Refs.id_of_url s.submission_url) s.submission_status)
;;

let admission_event_id (a : Model.Admission.t) =
  Event_id.of_string
    (sprintf "adm:%s:%s" (Refs.id_of_url a.admission_url) a.admission_status)
;;

let error_code text =
  (* The [code] field of a Griffin error as printed by griffin-client's [Api_error]. *)
  match String.substr_index text ~pattern:"(code (" with
  | None -> "refused"
  | Some i ->
    let rest = String.drop_prefix text (i + String.length "(code (") in
    String.take_while rest ~f:(fun c -> not (Char.equal c ')'))
;;

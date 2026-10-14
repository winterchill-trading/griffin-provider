open! Core
open Banking_provider
module Model = Griffin_client.Model

let status s : Ledger.Account_status.t =
  match s with
  | "closing" -> Frozen
  | "closed" -> Closed
  | _ -> Open
;;

let uk_details (a : Model.Bank_account.t) =
  List.find_map a.bank_addresses ~f:(fun b ->
    (let open Or_error.Let_syntax in
     let%bind sort_code = Payments_core.Sort_code.of_string b.bank_id in
     Payments_core.Uk_account.create ~sort_code ~account_number:b.account_number ())
    |> Result.ok)
;;

let account (a : Model.Bank_account.t) =
  let open Or_error.Let_syntax in
  let%bind () =
    Or_error.bind
      (Money.Currency.of_string_or_error a.account_balance.currency)
      ~f:Units.require_gbp
  in
  let%map owner =
    (* Embedded accounts name the customer as owner; organization accounts as beneficiary. *)
    match a.owner_url, a.beneficiary_url with
    | Some url, _ | None, Some url -> Ok url
    | None, None -> Or_error.error_s [%message "account has no owner" a.account_url]
  in
  { Account.id = Refs.account ~account_url:a.account_url
  ; customer = Refs.customer ~legal_person_url:owner
  ; currency = Money.Currency.gbp
  ; status = status a.account_status
  ; addresses =
      Option.map (uk_details a) ~f:(fun u -> Account.Address.Uk_account u)
      |> Option.to_list
  ; opened_at = Griffin_time.parse_or ~default:Time_ns.epoch a.created_at
  }
;;

let balance (a : Model.Bank_account.t) ~at =
  let open Or_error.Let_syntax in
  let%bind posted = Units.of_griffin a.account_balance in
  let%bind available =
    Option.value_map a.available_balance ~default:(Ok posted) ~f:Units.of_griffin
  in
  let%map held = Money.Amount.sub posted available in
  { Account.Balance.account = Refs.account ~account_url:a.account_url
  ; available
  ; held
  ; posted
  ; as_of = at
  }
;;

let at_of (t : Model.Transaction.t) =
  match Option.bind t.post_datetime ~f:Griffin_time.parse with
  | Some at -> at
  | None -> Griffin_time.parse_or ~default:Time_ns.epoch t.effective_at
;;

let line (t : Model.Transaction.t) =
  let open Or_error.Let_syntax in
  let%bind change = Units.of_griffin t.balance_change in
  let%bind amount =
    match t.balance_change_direction with
    | "credit" -> Ok change
    | "debit" -> Ok (Money.Amount.neg change)
    | other -> Or_error.error_s [%message "unknown direction" other]
  in
  let%map balance = Units.of_griffin t.account_balance in
  { Statement.Line.at = at_of t
  ; amount
  ; code =
      String.uppercase t.transaction_origin_type |> String.tr ~target:'-' ~replacement:'_'
  ; reference =
      (match t.payment_url with
       | Some url -> Refs.id_of_url url
       | None ->
         Option.value t.reference ~default:(Refs.id_of_url t.account_transaction_url))
  ; balance
  }
;;

let statement account ~from ~until txs =
  let open Or_error.Let_syntax in
  let%bind lines = List.map txs ~f:line |> Or_error.all in
  let lines =
    List.sort lines ~compare:(fun (a : Statement.Line.t) b -> Time_ns.compare a.at b.at)
  in
  let before, rest = List.partition_tf lines ~f:(fun l -> Time_ns.( < ) l.at from) in
  let inside = List.filter rest ~f:(fun l -> Time_ns.( < ) l.at until) in
  let zero = Money.Amount.zero Money.Currency.gbp in
  let%bind opening =
    match List.last before, List.hd rest with
    | Some l, _ -> Ok l.balance
    | None, Some first -> Money.Amount.sub first.balance first.amount
    | None, None -> Ok zero
  in
  let%bind closing =
    Money.Amount.sum Money.Currency.gbp (opening :: List.map inside ~f:(fun l -> l.amount))
  in
  let s =
    { Statement.account
    ; currency = Money.Currency.gbp
    ; from
    ; until
    ; opening
    ; lines = inside
    ; closing
    }
  in
  let%map () = Statement.check s in
  s
;;

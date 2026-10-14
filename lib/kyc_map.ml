open! Core
open Banking_provider
open Kyc_core
module Model = Griffin_client.Model

(* kyc-core has its own [Event] and [Event_id]; these are the provider events. *)
module Event = Banking_provider.Event
module Event_id = Banking_provider.Event_id

(* {2 Claims} *)

let display_name (p : Person.t) =
  sprintf "%s, %s" (String.uppercase (Pii.reveal p.family_name)) (Pii.reveal p.given_name)
;;

let claim ty fields = `Assoc (("claim-type", `String ty) :: fields)
let opt name v = Option.map v ~f:(fun v -> name, `String v) |> Option.to_list
let uk_like = [ "GB"; "GG"; "IM"; "JE" ]

(* "10 Downing Street" -> building number "10", street "Downing Street". *)
let split_building line =
  match String.lsplit2 (String.strip line) ~on:' ' with
  | Some (number, street)
    when (not (String.is_empty number))
         && Char.is_digit number.[0]
         && not (String.is_empty (String.strip street)) ->
    [ "building-number", `String number; "street-name", `String (String.strip street) ]
  | _ -> [ "building-name", `String line; "street-name", `String line ]
;;

let residence (a : Address.t) =
  let country = Country.to_string a.country in
  let common =
    [ "city", `String a.city; "country-code", `String country ]
    @ opt "postal-code" a.postal_code
  in
  if List.mem uk_like country ~equal:String.equal
  then claim "individual-residence" (split_building a.line1 @ common)
  else
    claim
      "individual-residence"
      ((("address-line-1", `String a.line1) :: opt "address-line-2" a.line2) @ common)
;;

let person_claims (p : Person.t) =
  [ claim
      "individual-identity"
      [ "given-name", `String (Pii.reveal p.given_name)
      ; "surname", `String (Pii.reveal p.family_name)
      ; "date-of-birth", `String (Date.to_string (Pii.reveal p.date_of_birth))
      ]
  ; claim "contact-details" [ "email-address", `String (Pii.reveal p.email) ]
  ; residence (Pii.reveal p.residential_address)
  ; claim "mobile-number" [ "mobile-number", `String (Pii.reveal p.mobile) ]
  ; claim
      "nationality"
      [ "nationality", `String (Country.to_string (Pii.reveal p.nationality)) ]
  ]
;;

let strings l = `List (List.map l ~f:(fun s -> `String s))
let gbp v = `Assoc [ "currency", `String "GBP"; "value", `String v ]

(* The answers griffin-client's live walk onboarded with; Griffin's sandbox terms allow
   test data only. *)
let sandbox_questionnaire =
  [ claim
      "employment"
      [ "employment-status", `String "employed"
      ; "occupation", `String "construction-worker"
      ; "industry-of-occupation", `String "property-and-construction"
      ]
  ; claim "individual-income" [ "income", gbp "50000.00" ]
  ; claim "tax-residencies" [ "tax-residencies", strings [ "GB" ] ]
  ; claim "us-citizen" [ "us-citizen?", `Bool false ]
  ; claim
      "individual-purposes-of-account"
      [ "individual-purposes-of-account", strings [ "everyday-spending" ] ]
  ; claim
      "individual-sources-of-funds"
      [ "individual-sources-of-funds", strings [ "savings" ] ]
  ; claim "cash-payments" [ "cash-payments?", `Bool false ]
  ; claim "initial-deposit" [ "initial-deposit", gbp "100.00" ]
  ; claim
      "international-payments-countries"
      [ "international-payments-countries", strings [] ]
  ]
;;

(* {2 Status} *)

let step_state ~verification_status ~at : Verification.State.t =
  match verification_status with
  | "checks-complete" -> Verified at
  | "checks-declined" -> Failed "checks declined"
  | "failed" -> Failed "verification failed"
  | _ -> Sent
;;

let status (lp : Model.Legal_person.t) ~latest_verification : Status.t =
  match lp.latest_decision with
  | Some { decision_outcome = "accepted"; _ } -> Approved
  | Some { decision_outcome = "declined"; decision_notes; _ } ->
    Rejected
      (match decision_notes with
       | Some n when not (String.is_empty n) -> n
       | _ -> "declined")
  | _ -> if Option.is_some latest_verification then Verifying else Created
;;

let same_kind (a : Verification.State.t) (b : Verification.State.t) =
  match a, b with
  | Pending, Pending | Sent, Sent | Verified _, Verified _ | Expired, Expired -> true
  | Failed x, Failed y -> String.equal x y
  | _ -> false
;;

let checked_steps = [ Verification.Step.Identity_document; Address_proof ]

let kyc_status customer ?previous lp ~latest_verification ~at =
  let base = Customer.Kyc_status.initial customer in
  let keep step state =
    match previous with
    | None -> state
    | Some (p : Customer.Kyc_status.t) ->
      (match List.Assoc.find p.steps step ~equal:Verification.Step.equal with
       | Some old when same_kind old state -> old
       | _ -> state)
  in
  let with_steps =
    match latest_verification with
    | None -> base
    | Some (v : Model.Verification.t) ->
      let state = step_state ~verification_status:v.verification_status ~at in
      List.fold checked_steps ~init:base ~f:(fun acc step ->
        Customer.Kyc_status.with_step acc step (keep step state))
  in
  { with_steps with status = status lp ~latest_verification }
;;

let transitions ~(from : Status.t) ~(to_ : Status.t) : Status.Transition.t list =
  match from, to_ with
  | (Created | Needs_resubmission _), Verifying -> [ Submit ]
  | (Created | Needs_resubmission _), Approved -> [ Submit; Approve ]
  | Verifying, Approved -> [ Approve ]
  | (Created | Needs_resubmission _), Rejected r -> [ Submit; Reject r ]
  | Verifying, Rejected r -> [ Reject r ]
  | _ -> []
;;

let status_name (s : Status.t) =
  match s with
  | Created -> "Created"
  | Verifying -> "Verifying"
  | Approved -> "Approved"
  | Rejected _ -> "Rejected"
  | Needs_resubmission _ -> "Needs_resubmission"
  | Blocked _ -> "Blocked"
  | Closed _ -> "Closed"
;;

let transition_name (t : Status.Transition.t) =
  match t with
  | Submit -> "Submit"
  | Approve -> "Approve"
  | Reject _ -> "Reject"
  | Request_resubmission _ -> "Request_resubmission"
  | Block _ -> "Block"
  | Unblock -> "Unblock"
  | Close _ -> "Close"
;;

let state_name (s : Verification.State.t) =
  match s with
  | Pending -> "Pending"
  | Sent -> "Sent"
  | Verified _ -> "Verified"
  | Failed _ -> "Failed"
  | Expired -> "Expired"
;;

let events ~(previous : Customer.Kyc_status.t) ~(current : Customer.Kyc_status.t) ~at =
  let lp = Customer_ref.to_string current.customer in
  let event id update : Event.t =
    { id = Event_id.of_string (sprintf "kyc:%s:%s" lp id)
    ; at
    ; kind = Kyc { customer = current.customer; update }
    }
  in
  let steps =
    List.filter_map current.steps ~f:(fun (step, state) ->
      let before =
        List.Assoc.find previous.steps step ~equal:Verification.Step.equal
        |> Option.value ~default:Verification.State.Pending
      in
      if same_kind before state
      then None
      else
        Some
          (event
             (sprintf
                "step:%s:%s"
                (Sexp.to_string [%sexp (step : Verification.Step.t)])
                (state_name state))
             (Step { step; state })))
  in
  let _, statuses =
    List.fold_map
      (transitions ~from:previous.status ~to_:current.status)
      ~init:previous.status
      ~f:(fun from tr ->
        let next = Status.apply from tr ~actor:(Provider "griffin") |> Result.ok in
        ( Option.value next ~default:from
        , event (sprintf "%s:%s" (status_name from) (transition_name tr)) (Status tr) ))
  in
  steps @ statuses
;;

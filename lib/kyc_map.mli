(** Griffin onboarding in kyc-core terms.

    A Griffin customer is a {e legal person} described by claims (identity, residence,
    contact details, and the questionnaire answers a workflow asks for). A
    {e verification} runs the workflow's electronic checks over those claims, and a
    {e decision} (accepted or declined) concludes onboarding; in the sandbox the
    organization records it, in live mode Griffin's operations do.

    {v
      Griffin                               kyc-core
      verification pending, in-progress     Identity_document, Address_proof Sent
      verification checks-complete          Identity_document, Address_proof Verified
      verification checks-declined, failed  Identity_document, Address_proof Failed

      no verification                       Created
      a verification, no decision           Verifying
      latest decision accepted              Approved
      latest decision declined              Rejected
    v}

    Griffin's checks are electronic identity and address checks on the claims: there is no
    document upload, selfie, e-mail code or SMS code, so [Email], [Mobile], [Liveness] and
    [Source_of_funds] stay [Pending] and the derived tier stays [T0] even for an approved
    customer. Approval comes from the decision, not the tier. *)

open! Core
open Banking_provider
module Model := Griffin_client.Model

(** {2 Claims} *)

(** Griffin's display name convention, [SURNAME, Given]. *)
val display_name : Kyc_core.Person.t -> string

(** Identity, contact details, residence, nationality and mobile claims for [person].
    UK addresses (GB and the crown dependencies) are split into building number and
    street name; other countries use address lines. *)
val person_claims : Kyc_core.Person.t -> Yojson.Safe.t list

(** The answers the sandbox "Individual - Account Owners" workflow needs besides the
    person (employment, income, tax residency, purposes and sources of funds, ...): fixed
    test data, for sandbox runs only. A live service collects these from the customer. *)
val sandbox_questionnaire : Yojson.Safe.t list

(** {2 Status} *)

(** The state of the identity and address steps for a verification status. *)
val step_state : verification_status:string -> at:Time_ns.t -> Kyc_core.Verification.State.t

val status
  :  Model.Legal_person.t
  -> latest_verification:Model.Verification.t option
  -> Kyc_core.Status.t

(** The status and steps. A step whose state has not changed kind since [previous] keeps
    its earlier value (and its verification time); new verifications are stamped [at]. *)
val kyc_status
  :  Customer_ref.t
  -> ?previous:Customer.Kyc_status.t
  -> Model.Legal_person.t
  -> latest_verification:Model.Verification.t option
  -> at:Time_ns.t
  -> Customer.Kyc_status.t

(** The transitions that take a case from [from] to [to_] ([Created] to [Approved] is
    [Submit] then [Approve]); empty when they are equal or no transition leads there. *)
val transitions
  :  from:Kyc_core.Status.t
  -> to_:Kyc_core.Status.t
  -> Kyc_core.Status.Transition.t list

(** The events between two observations of one customer: each step that changed kind,
    then the status transitions. Ids are derived from the change
    ([kyc:<legal person>:step:<Step>:<State>], [kyc:<legal person>:<From>:<Transition>]),
    so the same change seen by a poll and by a webhook is one event. *)
val events
  :  previous:Customer.Kyc_status.t
  -> current:Customer.Kyc_status.t
  -> at:Time_ns.t
  -> Event.t list

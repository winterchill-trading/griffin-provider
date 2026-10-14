(** Griffin payments, submissions and admissions as transfer states and events.

    An outgoing payment is a {e payment} (which moves nothing) plus a {e submission} to a
    scheme (Faster Payments or a book transfer inside Griffin); an incoming one is an
    inbound payment plus an {e admission}.

    {v
      submission scheduled   Submitted      admission processing  deposit, pending
      submission processing  Pending        admission delivered   deposit, settled
      submission delivered   Settled        admission returned    Returned MS03
      submission failed      Rejected       admission cancelled   Rejected MS03
      submission returned    Returned MS03
    v}

    Griffin's scheme status codes are not ISO 20022 reasons: a four-character one is kept
    as such ([Other]), anything else becomes [MS03] (not specified, agent generated).

    {b Rail.} payments-core has no Faster Payments rail yet, and its SEPA rails accept
    only EUR. GBP payments are therefore reported on [Intraledger] with [Intraledger]
    details, the only bank rail whose validation accepts GBP, so that
    [Event.incoming_transfer] and the transfer state machine work unchanged; the scheme
    and the counterparty's sort code and account number are kept in the counterparty
    text. *)

open! Core
open Banking_provider
open Payments_core
module Model := Griffin_client.Model

(** The rail GBP payments are reported on (see above). *)
val rail : Rail.t

(** Griffin's [fps] or [book-transfer], as text for counterparty details. *)
val scheme_name : [ `Fps | `Book_transfer ] -> string

(** A scheme status code as a reason ([MS03] when absent or not four characters). *)
val reason : string option -> Iso_reason.t

val submission_status : Model.Submission.t -> Transfer.Status.t
val submission_update : Model.Submission.t -> Transfer_update.t

(** [Sort code account number (holder)] of a debtor or creditor, as reported. *)
val party_text : Model.Party.t -> string

(** The [Incoming_transfer] for an inbound payment admitted to [account]; [None] while
    the admission says nothing about money arriving ([returned], [cancelled]: those are
    {!admission_update}s). *)
val incoming
  :  Model.Admission.t
  -> Model.Payment.t
  -> Event.Kind.t option Or_error.t

(** A later admission state of a deposit: [Returned] or [Rejected] with [MS03]. *)
val admission_update : Model.Admission.t -> Transfer_update.t option

(** Event ids derived from the change, so a poll, a webhook and a status query report it
    once: [sub:<submission id>:<status>], [adm:<admission id>:<status>]. *)
val submission_event_id : Model.Submission.t -> Event_id.t

val admission_event_id : Model.Admission.t -> Event_id.t

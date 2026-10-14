(** {!Banking_provider.Provider.S} and {!Banking_provider.Sandbox.S} over the Griffin API
    ([griffin-client]): UK onboarding, GBP accounts, Faster Payments and book transfers.

    {b Ids.} A customer is a Griffin legal person and an account a Griffin bank account
    ({!Refs}). Griffin has no idempotency keys and no field for our ids, so the links that
    make creates idempotent (our customer id, a customer's account, our transfer id) live
    in a {!Store.t}; [open_account] also finds an account the store lost by listing the
    legal person's accounts.

    {b Payments.} [initiate_transfer] creates a Griffin payment and submits it. A
    beneficiary held as a GB IBAN, or an [Internal] beneficiary naming a sort code and
    account number ([04-00-04 12345678]), is paid by Faster Payments; an [Internal]
    beneficiary naming a Griffin account id ([ba.]) by a book transfer. Griffin runs no
    customer authentication on payments, so no SCA challenge is ever returned. GBP
    payments are reported on the [Intraledger] rail until payments-core has a Faster
    Payments rail ({!Tx_map}).

    {b Events.} Griffin posts every organization event to one webhook; a service passes
    each delivery to {!ingest_webhook}. Without one, the adapter polls the organization's
    event log while anything is subscribed to {!events}. Both paths derive the same event
    ids from Griffin's data, and calls that observe a change ([kyc_status], [transfer])
    publish it too.

    {b Not offered by Griffin through this adapter} (each answers an error saying so):
    cards, swaps, standing orders, crypto, SCA, e-mail and SMS codes, and any currency but
    GBP. *)

open! Core
open Async
open Banking_provider

module Config : sig
  type t =
    { poll_interval : Time_ns.Span.t
    ; open_timeout : Time_ns.Span.t
    (** how long [open_account] waits for an account to open, and the sandbox simulations
        for checks and payments to finish *)
    ; customer_product_class : string
    (** the bank account product class opened for customers ([embedded]) *)
    ; workflow : string (** the onboarding workflow's display name *)
    ; questionnaire : Kyc_core.Customer_id.t -> Yojson.Safe.t list
    (** claims the workflow needs besides the person (see
        {!Kyc_map.sandbox_questionnaire}) *)
    ; display_name : Kyc_core.Customer_id.t -> Kyc_core.Person.t -> string
    ; funding_account : string option
    (** account URL [simulate_deposit] pays from; by default the organization's open
        operational account with the largest balance *)
    ; webhook_authority : string option
    (** host (and port) the webhook URL points at, when the receiving server does not pass
        a [host] header *)
    ; webhook_path : string (** request path of the webhook URL *)
    ; ping_via_webhook_test : bool
    (** [ping] asks Griffin for a test delivery to the organization's webhook; off by
        default, because that webhook may belong to another integration *)
    ; event_lookback : Time_ns.Span.t (** how far before [create] the event poll starts *)
    }

  (** Polls every 2 s, waits up to 2 minutes, opens [embedded] accounts, onboards with
      ["Individual - Account Owners"] and the sandbox questionnaire, display names
      [SURNAME, Given], webhook path [/webhooks/griffin], publishes [ping] locally, and
      looks one minute back. *)
  val default : t
end

type t

(** An adapter over a connected client; [store] defaults to {!Store.memory}. *)
val create : ?config:Config.t -> ?store:Store.t -> Griffin_client.Client.t -> t

(** Connects with [GRIFFIN_*] environment variables (see griffin-client's [Config]);
    refuses a live organization unless [~live:true]. *)
val of_env
  :  ?config:Config.t
  -> ?store:Store.t
  -> ?live:bool
  -> unit
  -> t Or_error.t Deferred.t

(** The client underneath, for Griffin calls the interface does not cover. *)
val client : t -> Griffin_client.Client.t

include Provider.S with type t := t
include Sandbox.S with type t := t

(** {2 Griffin-specific} *)

(** The sort code and account number of an open account, which [Account.t] cannot carry. *)
val uk_details : t -> Account_ref.t -> Uk_account.t Or_error.t Deferred.t

(** Confirmation of Payee for a payment [customer] is about to make: does [name] match the
    account holder at the receiving bank? [account-not-found] and other refusals by the
    receiving bank give [Not_possible]. When [beneficiary] is given the answer is also
    published as a [Payee_check] event. *)
val confirm_payee
  :  ?beneficiary:Payments_core.Beneficiary.Id.t
  -> ?business:bool
  -> t
  -> customer:Customer_ref.t
  -> name:string
  -> Uk_account.t
  -> Payments_core.Beneficiary.Payee_check.t Or_error.t Deferred.t

(** Sandbox only: Griffin's simulated Confirmation of Payee answer ([full-match],
    [close-match-name], [no-match-name], [account-not-found], ...). *)
val simulate_confirm_payee
  :  t
  -> customer:Customer_ref.t
  -> name:string
  -> Uk_account.t
  -> outcome:string
  -> Payments_core.Beneficiary.Payee_check.t Or_error.t Deferred.t

(** The answer of a Confirmation of Payee response ([match], [close-match] with a
    suggested name, [no-match]). *)
val payee_check
  :  Griffin_client.Model.Cop_response.t
  -> Payments_core.Beneficiary.Payee_check.t

(** Failures inside the poller, which has no caller to return them to. *)
val background_errors : t -> Error.t list

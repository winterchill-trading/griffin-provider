(** Griffin bank accounts as [Banking_provider.Account.t], balances and statements.

    A Griffin account is GBP only and is addressed by a sort code and an account number,
    reported as its one [Account.Address.Uk_account] once the account is open. Griffin
    issues no IBAN. *)

open! Core
open Banking_provider
module Model := Griffin_client.Model

(** [open] and [opening] are open, [closing] frozen (nothing goes out), [closed] closed. *)
val status : string -> Ledger.Account_status.t

(** Fails for an account without an owner or in another currency. The sort code and
    account number, once assigned, are its address. *)
val account : Model.Bank_account.t -> Account.t Or_error.t

(** The first sort code and account number of the account; [None] while it is opening. *)
val uk_details : Model.Bank_account.t -> Payments_core.Uk_account.t option

(** [posted] is the account balance, [available] what Griffin reports as available (the
    same when it reports none), [held] the difference. *)
val balance : Model.Bank_account.t -> at:Time_ns.t -> Account.Balance.t Or_error.t

(** One posted transaction as a statement line: signed by its direction, coded by its
    origin ([PAYMENT], [DEPOSIT], [FEE], ...), referenced by its payment id when it has
    one. *)
val line : Model.Transaction.t -> Statement.Line.t Or_error.t

(** A statement over [\[from, until)] from transactions in any order that include, when
    the account is older than [from], at least the last one before [from]: its balance is
    the opening balance. Without an earlier transaction the opening balance is what the
    account held before the first one (zero for a new account). *)
val statement
  :  Account_ref.t
  -> from:Time_ns.t
  -> until:Time_ns.t
  -> Model.Transaction.t list
  -> Statement.t Or_error.t

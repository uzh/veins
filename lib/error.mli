(** Error types and exception raised by Veins query helpers.

    @canonical Veins.Error *)

(** Errors that can occur during pool operations, queries, and migrations. *)
type t =
  | Connection_failed of string
  (** A connection attempt failed, e.g. bad URL or server unreachable. *)
  | Database_not_registered of string
  (** [Pool.fetch] was called for a label that was never registered
      with [Pool.initialize] or [Pool.add]. *)
  | Migration_failed of string (** A migration step returned an error. *)
  | Caqti_error of string (** A Caqti driver error (string representation). *)

(** Raised by query helpers ([exec], [find], [collect], …) when an
    unrecoverable error occurs.  Transactions catch this exception,
    roll back, and re-raise it. *)
exception Exn of t

(** Human-readable one-line description of an error. *)
val show : t -> string

(** [pp fmt t] prints {!show} [t] to [fmt]. *)
val pp : Format.formatter -> t -> unit

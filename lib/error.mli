(** Errors raised by Veins.

    Two exceptions:
    - {!Failed} for everything the database (or the driver) reported: it
      carries the label, the role and the untouched caqti error, so callers
      can match on {!cause} (e.g. [`Unique_violation]) instead of on rendered
      strings.
    - {!Exn} for errors Veins detects itself: unknown databases, missing
      roles, missing capabilities, failed migrations.

    @canonical Veins.Error *)

type t =
  | Connection_failed of string
  (** A connection attempt failed, e.g. bad URL or server unreachable. *)
  | Database_not_registered of string
  (** The label was never registered with [Pool.initialize] or [Pool.add]. *)
  | Role_required of string
  (** A context without a role was used on a database with one URL per role
      ([Multiple]). Carries the label. *)
  | Role_not_configured of
      { label : string
      ; role : string
      }
  (** The role isn't one of the database's roles, or was named on a
      single-URL database with the [Strict] policy. *)
  | Insufficient_capabilities of
      { label : string
      ; role : string option
      ; missing : string list
      }
  (** The statement needs capabilities its context's role doesn't have. It
      was not sent. *)
  | Migration_failed of string (** A migration step returned an error. *)
  | Unsupported of string (** The driver doesn't support an operation. *)

(** Raised for the errors of {!t}. *)
exception Exn of t

val show : t -> string
val pp : Format.formatter -> t -> unit

type failure =
  { label : Entity.Label.t
  ; role : Entity.Role.t option
  ; error : Caqti_error.t
  }

(** Raised by every statement the database or driver rejected. *)
exception Failed of failure

val failure : ?role:Entity.Role.t -> Entity.Label.t -> Caqti_error.t -> failure

(** caqti's classification of a statement the server rejected. [None] for
    errors that carry no cause (connecting, encoding, decoding). *)
val cause : Caqti_error.t -> Caqti_error.cause option

(** {!cause} for an exception, covering both {!Failed} and [Caqti_error.Exn]. *)
val cause_of_exn : exn -> Caqti_error.cause option

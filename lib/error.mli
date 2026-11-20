(** Errors raised by Veins.

    Two exceptions:
    - {!Failed} for everything the database (or the driver) reported: it
      carries the label, the login, the role and the untouched caqti error,
      so callers can match on {!cause} (e.g. [`Unique_violation]) instead of
      on rendered strings.
    - {!Exn} for errors Veins detects itself (unknown databases, failed
      migrations) and for {!Permission_denied}.

    Whether a statement fits its context's role is checked by the compiler
    ({!Ctx.t}), so there is no runtime error for it.

    @canonical Veins.Error *)

type t =
  | Connection_failed of string
  (** A connection attempt failed, e.g. bad URL or server unreachable. *)
  | Acquire_timeout of string
  (** No connection of the pool became free within
      [Pool_options.acquire_timeout]: the pool is exhausted (or still
      connecting), but veins neither drops nor reconnects it, so this is not a
      connection error ([Pools_sig.Sig.is_connection_error] is [false]). *)
  | Database_not_registered of string
  (** The label was never registered with [Pool.initialize] or [Pool.add]. *)
  | Permission_denied of
      { label : string
      ; login : string
      ; role : string option
      ; needs : string list
      ; message : string (** The database's error. *)
      }
  (** The database refused a statement for lack of privileges (MariaDB
      errors 1044, 1142, 1143, 1227, 1370; PostgreSQL SQLSTATE 42501). The
      types allowed it, so the login is missing a grant its role claims, or
      the statement declared fewer needs than it has: a setup bug. Only the
      driver libraries recognise these errors ({!Driver.Sig}). *)
  | Login_not_configured of
      { label : string
      ; login : string
      }
  (** A role connects as a login the database has no URL for, and the
      database doesn't let logins share the owner's
      ([Database.create ~strict_logins:true]). *)
  | Migration_failed of string
  (** A migration step failed, or the migrations refused to run. *)
  | Migration_not_clean of (string * string) list
  (** Databases whose migration state isn't clean, by label, with their
      status ([Migration.App_sig.ensure_clean]). *)
  | Unsupported of string (** The driver doesn't support an operation. *)

(** Raised for the errors of {!t}. *)
exception Exn of t

val show : t -> string
val pp : Format.formatter -> t -> unit

type failure =
  { label : Entity.Label.t
  ; login : Entity.Login.t
  ; role : string option (** The context's role, if a statement failed. *)
  ; error : Caqti.Error.t
  }

(** Raised by every statement the database or driver rejected. *)
exception Failed of failure

val failure
  :  ?role:string
  -> login:Entity.Login.t
  -> Entity.Label.t
  -> Caqti.Error.t
  -> failure

(** caqti's classification of a statement the server rejected. [None] for
    errors that carry no cause (connecting, encoding, decoding). *)
val cause : Caqti.Error.t -> Caqti.Error.cause option

(** {!cause} for an exception, covering both {!Failed} and [Caqti.Error.Exn]. *)
val cause_of_exn : exn -> Caqti.Error.cause option

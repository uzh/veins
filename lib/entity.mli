(** Entity types used throughout Veins. *)

(** @canonical Veins.Label *)
module Label : sig
  type t

  val create : string -> t
  val value : t -> string
  val equal : t -> t -> bool
  val compare : t -> t -> int
  val hash : t -> int
  val pp : Format.formatter -> t -> unit
  val show : t -> string
end

(** A role name for a database user, e.g. ["readonly"] or ["write"].

    Deliberately separate from {!Label} so the two cannot be accidentally
    swapped.

    @canonical Veins.Role *)
module Role : sig
  type t

  val create : string -> t
  val value : t -> string
  val equal : t -> t -> bool
  val pp : Format.formatter -> t -> unit
  val show : t -> string
end

(** @canonical Veins.Url *)
module Url : sig
  type t

  val create : string -> t
  val to_uri : t -> Uri.t
  val equal : t -> t -> bool
  val pp : Format.formatter -> t -> unit
  val show : t -> string
end

(** @canonical Veins.Status *)
module Status : sig
  type t =
    | Active
    | ConnectionIssue
    | Disabled
    | Maintenance
    | MigrationsConnectionIssue
    | MigrationsFailed
    | MigrationsPending

  val all : t list
  val equal : t -> t -> bool
  val show : t -> string
  val of_string : string -> (t, string) result
  val pp : Format.formatter -> t -> unit
end

(** @canonical Veins.Database *)
module Database : sig
  type pool =
    | Main of Url.t
    | Multiple of (Role.t * Url.t) list

  type t =
    { label : Label.t
    ; status : Status.t
    ; pool : pool
    }

  (** [create label pool] builds a database entry.

      For [Multiple roles], role names must be unique;
      duplicates raise [Invalid_argument]. *)
  val create : ?status:Status.t -> Label.t -> pool -> t

  val label : t -> Label.t

  (** [url t] returns the connection URL for [t].

      - [Main] pool: returns the primary URL; [role] is ignored (with a warning).
      - [Multiple] pool: [role] is required; raises [Invalid_argument] if
        omitted or if the role is not found. *)
  val url : ?role:Role.t -> t -> Url.t

  val status : t -> Status.t
  val pool : t -> pool
end

(** @canonical Veins.Dynparam *)
module Dynparam : sig
  type t = Pack : 'a Caqti_type.t * 'a -> t

  val empty : t
  val add : 'a Caqti_type.t -> 'a -> t -> t
  val prefix : 'a Caqti_type.t -> 'a -> t -> t
end

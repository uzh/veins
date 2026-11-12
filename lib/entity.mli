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

(** A right a statement needs, defined by the application or library, e.g.
    [Capability.create "billing_write"].

    Capabilities are values: create each one once, at module level, and refer
    to it by its OCaml name, so a typo is a compile error. The name only shows
    up in logs and errors. Names are unique per process: creating a second
    capability with the same name raises [Invalid_argument], so two libraries
    can't silently share one.

    @canonical Veins.Capability *)
module Capability : sig
  type t

  (** Raises [Invalid_argument] if a capability named [name] already exists. *)
  val create : string -> t

  val name : t -> string
  val equal : t -> t -> bool
  val compare : t -> t -> int
  val pp : Format.formatter -> t -> unit
  val show : t -> string

  module Set : sig
    type elt = t
    type t

    val empty : t
    val of_list : elt list -> t
    val elements : t -> elt list
    val mem : elt -> t -> bool
    val union : t -> t -> t
    val diff : t -> t -> t
    val subset : t -> t -> bool
    val is_empty : t -> bool
    val equal : t -> t -> bool
    val pp : Format.formatter -> t -> unit
  end
end

(** A database user and the capabilities it has been granted, e.g.
    [Role.create "reader" ~capabilities:[ read ]].

    Roles exist for privilege separation: every role of a database connects
    to the same server and data, as a different user. Veins never picks a role
    by itself; a context names its role, and every statement is checked
    against that role's capabilities before it is sent.

    Deliberately separate from {!Label} so the two cannot be accidentally
    swapped. Roles are compared by name.

    @canonical Veins.Role *)
module Role : sig
  type t

  val create : ?capabilities:Capability.t list -> string -> t
  val value : t -> string
  val capabilities : t -> Capability.Set.t
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
    | Main of Url.t (** One URL, one database user with every capability. *)
    | Multiple of (Role.t * Url.t) list
    (** One URL (and database user) per role. A single user with all rights
        works too: give every role the same URL. *)

  (** What a context that names a role does on a [Main] database:
      [Fallback] (the default) uses the main pool, so code written for roles
      runs unchanged on a single-URL setup; [Strict] rejects it with
      [Error.Role_not_configured]. *)
  type role_policy =
    | Fallback
    | Strict

  type t =
    { label : Label.t
    ; status : Status.t
    ; pool : pool
    ; role_policy : role_policy
    }

  (** [create label pool] builds a database entry.

      For [Multiple roles], role names must be unique and the list non-empty;
      otherwise raises [Invalid_argument]. *)
  val create : ?status:Status.t -> ?role_policy:role_policy -> Label.t -> pool -> t

  val label : t -> Label.t
  val status : t -> Status.t
  val pool : t -> pool
  val role_policy : t -> role_policy

  (** Roles of a [Multiple] database, [[]] for [Main]. *)
  val roles : t -> Role.t list

  (** [find_role t role] is the role of [t] named like [role], with the
      capabilities [t] was configured with. *)
  val find_role : t -> Role.t -> Role.t option

  (** [url t] returns the connection URL for [t].

      - [Main]: the URL; with [~role], only under the [Fallback] policy.
      - [Multiple]: the URL of [~role].

      Raises [Invalid_argument] if [~role] is missing for [Multiple], unknown,
      or given for a [Strict] [Main] database. *)
  val url : ?role:Role.t -> t -> Url.t
end

(** @canonical Veins.Dynparam *)
module Dynparam : sig
  type t = Pack : 'a Caqti_type.t * 'a -> t

  val empty : t
  val add : 'a Caqti_type.t -> 'a -> t -> t
  val prefix : 'a Caqti_type.t -> 'a -> t -> t
end

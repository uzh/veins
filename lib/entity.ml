(** Core domain types for Veins database entries. *)

(** A short, human-readable identifier for a database connection.
    Typically something like ["root"], ["tenant_acme"], or ["analytics"]. *)
module Label : sig
  type t

  val create : string -> t
  val value : t -> string
  val equal : t -> t -> bool
  val compare : t -> t -> int
  val hash : t -> int
  val pp : Format.formatter -> t -> unit
  val show : t -> string
end = struct
  type t = string

  let create s = s
  let value s = s
  let equal = String.equal
  let compare = String.compare
  let hash = Hashtbl.hash
  let pp fmt s = Format.pp_print_string fmt s
  let show s = s
end

(** A database connection URL, e.g.
    [mariadb://user:pass@host/dbname] or [postgresql://…]. *)
module Url : sig
  type t

  val create : string -> t
  val value : t -> string
  val to_uri : t -> Uri.t
  val equal : t -> t -> bool
  val pp : Format.formatter -> t -> unit
  val show : t -> string
end = struct
  type t = string

  let create s = s
  let value s = s
  let to_uri s = Uri.of_string s
  let equal = String.equal
  let pp fmt s = Format.pp_print_string fmt s
  let show s = s
end

(** Lifecycle status of a registered database connection pool. *)
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
end = struct
  type t =
    | Active
    | ConnectionIssue
    | Disabled
    | Maintenance
    | MigrationsConnectionIssue
    | MigrationsFailed
    | MigrationsPending

  let all =
    [ Active
    ; ConnectionIssue
    ; Disabled
    ; Maintenance
    ; MigrationsConnectionIssue
    ; MigrationsFailed
    ; MigrationsPending
    ]
  ;;

  let show = function
    | Active -> "active"
    | ConnectionIssue -> "connection_issue"
    | Disabled -> "disabled"
    | Maintenance -> "maintenance"
    | MigrationsConnectionIssue -> "migrations_connection_issue"
    | MigrationsFailed -> "migrations_failed"
    | MigrationsPending -> "migrations_pending"
  ;;

  let equal a b = String.equal (show a) (show b)

  let of_string = function
    | "active" -> Ok Active
    | "connection_issue" -> Ok ConnectionIssue
    | "disabled" -> Ok Disabled
    | "maintenance" -> Ok Maintenance
    | "migrations_connection_issue" -> Ok MigrationsConnectionIssue
    | "migrations_failed" -> Ok MigrationsFailed
    | "migrations_pending" -> Ok MigrationsPending
    | s -> Error ("Unknown database status: " ^ s)
  ;;

  let pp fmt t = Format.pp_print_string fmt (show t)
end

(** A registered database entry. *)
module Database : sig
  type t =
    { label : Label.t
    ; url : Url.t
    ; status : Status.t
    }

  val create : ?status:Status.t -> Label.t -> Url.t -> t
  val label : t -> Label.t
  val url : t -> Url.t
  val status : t -> Status.t
end = struct
  type t =
    { label : Label.t
    ; url : Url.t
    ; status : Status.t
    }

  let create ?(status = Status.Active) label url = { label; url; status }
  let label { label; _ } = label
  let url { url; _ } = url
  let status { status; _ } = status
end

(** Dynamic parameter accumulator for queries whose arity is not known at
    compile time (e.g. variable-length [IN (…)] clauses). *)
module Dynparam : sig
  type t = Pack : 'a Caqti_type.t * 'a -> t

  val empty : t
  val add : 'a Caqti_type.t -> 'a -> t -> t
  val prefix : 'a Caqti_type.t -> 'a -> t -> t
end = struct
  type t = Pack : 'a Caqti_type.t * 'a -> t

  let empty = Pack (Caqti_type.unit, ())
  let add t x (Pack (t', x')) = Pack (Caqti_type.t2 t' t, (x', x))
  let prefix t x (Pack (t', x')) = Pack (Caqti_type.t2 t t', (x, x'))
end

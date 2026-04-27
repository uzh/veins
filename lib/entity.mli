(** Public interface for {!Entity}. *)

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

module Url : sig
  type t

  val create : string -> t
  val value : t -> string
  val to_uri : t -> Uri.t
  val equal : t -> t -> bool
  val pp : Format.formatter -> t -> unit
  val show : t -> string
end

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
end

module Dynparam : sig
  type t = Pack : 'a Caqti_type.t * 'a -> t

  val empty : t
  val add : 'a Caqti_type.t -> 'a -> t -> t
  val prefix : 'a Caqti_type.t -> 'a -> t -> t
end

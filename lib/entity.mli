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

(** A database user a role connects as, e.g. [Login.create "query"].

    A database has one URL of its own, the {!owner}'s, plus an optional URL
    per login ({!Database.create}). A login without a URL of its own connects
    with the owner's, so a database with a single user for everything needs no
    configuration beyond that URL.

    @canonical Veins.Login *)
module Login : sig
  type t

  (** The database's own URL. Roles connect as the owner unless they name
      another login. *)
  val owner : t

  (** Raises [Invalid_argument] for ["owner"], see {!owner}. *)
  val create : string -> t

  val name : t -> string
  val is_owner : t -> bool
  val equal : t -> t -> bool
  val compare : t -> t -> int
  val hash : t -> int
  val pp : Format.formatter -> t -> unit
  val show : t -> string
end

(** The rights a statement needs, as a type.

    The type parameter is a lower bound of polymorphic variant tags that the
    application chooses, e.g. [`Read], [`Write], [`Ddl]. Declare each need
    once, with its type:

    {[
    let read : [> `Read ] Veins.Need.t = Veins.Need.v "read"
    let write : [> `Write ] Veins.Need.t = Veins.Need.v "write"
    ]}

    A statement needing both has [Need.(read & write)], of type
    [[> `Read | `Write ] Need.t]. A statement can only run on a context whose
    role has every tag ({!Role}), which the compiler checks. The names show up
    in errors only.

    @canonical Veins.Need *)
module Need : sig
  type +'g t

  (** [v name] is a need named [name]. Its type is whatever the declaration
      says, so declare each need once, with a type annotation. *)
  val v : string -> 'g t

  (** Needs nothing: the statement runs on every context. For statements
      that touch no data (e.g. [SELECT 1]) and for code that hasn't declared
      its needs yet. *)
  val none : 'g t

  (** Both needs. *)
  val ( & ) : 'g t -> 'g t -> 'g t

  val names : _ t -> string list
  val pp : Format.formatter -> _ t -> unit
end

(** A role: what a part of the application may do, and the {!Login} it
    connects as.

    The type parameter is the closed set of tags the role grants. Declare
    each role once, with its type:

    {[
    let query : [ `Read ] Veins.Role.t =
      Veins.Role.v ~login:(Veins.Login.create "query") "query"
    ;;

    let command : [ `Read | `Write ] Veins.Role.t =
      Veins.Role.v ~login:(Veins.Login.create "command") "command"
    ;;
    ]}

    Contexts carry their role's type ({!Ctx.t}), so a statement needing
    [`Write] on a [query] context is a compile error. Several roles may share
    a login: the database then enforces only what the login is granted, and
    the types the rest.

    The declaration is a claim the database has to back: if a login lacks a
    grant its roles claim, the statement fails with
    [Error.Permission_denied].

    @canonical Veins.Role *)
module Role : sig
  type 'g t

  (** [v ?login name] is a role named [name], connecting as [login] (default
      {!Login.owner}). Its type is whatever the declaration says. *)
  val v : ?login:Login.t -> string -> 'g t

  (** The database owner: connects with the database's own URL and accepts
      every statement. For migrations, tests and code that doesn't separate
      rights. *)
  val owner : 'g t

  val name : _ t -> string
  val login : _ t -> Login.t
  val pp : Format.formatter -> _ t -> unit
  val show : _ t -> string
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
  type t =
    { label : Label.t
    ; status : Status.t
    ; owner : Url.t (** The database's own URL, see {!Login.owner}. *)
    ; logins : (Login.t * Url.t) list (** URLs of the other logins. *)
    }

  (** [create ?logins label owner_url] builds a database entry. Logins
      missing from [logins] connect with [owner_url].

      Raises [Invalid_argument] for a duplicate login or {!Login.owner} in
      [logins]. *)
  val create : ?status:Status.t -> ?logins:(Login.t * Url.t) list -> Label.t -> Url.t -> t

  val label : t -> Label.t
  val status : t -> Status.t
  val owner : t -> Url.t

  (** The logins with a URL of their own. *)
  val logins : t -> Login.t list

  (** [true] if the login has a URL of its own. *)
  val has_login : t -> Login.t -> bool

  (** The URL [login] connects with: its own, or the owner's. *)
  val url : t -> Login.t -> Url.t
end

(** @canonical Veins.Dynparam *)
module Dynparam : sig
  type t = Pack : 'a Caqti_type.t * 'a -> t

  val empty : t
  val add : 'a Caqti_type.t -> 'a -> t -> t
  val prefix : 'a Caqti_type.t -> 'a -> t -> t
end

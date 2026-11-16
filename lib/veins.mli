(** Veins — database connection pooling for OCaml.

    {b Quick-start}

    {[
    (* 1. Instantiate the pool *)
    module Db = Veins_mariadb.Pools.Make (struct
        let database =
          let url = Veins.Url.create (Sys.getenv "DATABASE_URL") in
          Veins.Database.create (Veins.Label.create "root") url
        ;;
      end)

    (* 2. Declare what statements need, and what roles grant *)
    let read : [> `Read ] Veins.Need.t = Veins.Need.v "read"
    let query : [ `Read ] Veins.Role.t = Veins.Role.v "query"

    let find_name =
      {sql| SELECT name FROM users WHERE id = ? |sql}
      |> Caqti.Templater.(static T.(int -->? string))
      |> Veins.Request.create ~needs:read
    ;;

    (* 3. Run them on a context *)
    let () =
      Db.Pool.initialize ();
      let root = Veins.Label.create "root" in
      Lwt_main.run
        (let%lwt name = Db.find_opt (Db.label_ctx ~role:query root) find_name 1 in
         Db.transaction_ctx ~role:query root (fun ctx ->
           Veins.Ctx.after_commit ctx (fun () -> print_endline "committed");
           Db.find_opt ctx find_name 2))
    ;;
    ]}

    {b Roles.} A role ({!Role}) is a part of the application with a type:
    the tags it grants, e.g. [[ `Read ]]. A statement's {!Need} is a lower
    bound of tags, e.g. [[> `Write ]]. Every context carries its role's type,
    so running a statement on a context whose role doesn't grant its needs
    is a compile error, and a function's signature shows the rights it
    needs.

    Each role connects as a {!Login}. A database has the owner's URL and,
    optionally, one URL per login; logins without one connect as the owner.
    The database then enforces each login's grants, and refuses a statement
    the types allowed with [Error.Permission_denied]; with a single URL only
    the types separate the roles.

    {b Without roles.} An application with one database user for everything
    takes {!Plain} instead ([Veins_mariadb.Plain.Make]): contexts without
    a role, plain Caqti requests, no [~role] and no [~needs].

    {b Libraries.} The opam package [veins] installs the library [veins]
    and, when their Caqti driver is installed, [veins.mariadb]
    ([Veins_mariadb], needs [caqti-driver-mariadb]) and [veins.postgresql]
    ([Veins_postgresql], needs [caqti-driver-postgresql]). Name the library
    in dune, and the driver next to [veins] in your opam file.

    The context design ({!Ctx}) comes from Reynir Björnsson's database
    refactoring of the pool tool (uzh/z-pool-tool#647). *)

(** {1 Databases} *)

(** The name a database is registered under, and the key of its pools. *)
module Label = Entity.Label

(** Database connection URL. Opaque: the raw connection string is not
    accessible after construction, and [pp] / [show] mask its password. Pass
    the value to {!Database.create}. *)
module Url : sig
  type t = Entity.Url.t

  val create : string -> t
  val equal : t -> t -> bool
  val pp : Format.formatter -> t -> unit
  val show : t -> string
end

(** A database user a role connects as. *)
module Login = Entity.Login

(** Connection and migration status of a database entry. *)
module Status = Entity.Status

(** A database to register: its label, the owner's URL and the URLs of its
    other logins. *)
module Database = Entity.Database

(** {1 Roles} *)

(** The rights a statement needs, as a type. *)
module Need = Entity.Need

(** A part of the application, with the rights it has as a type, and the
    login it connects as. *)
module Role = Entity.Role

(** {1 Statements} *)

(** Caqti requests with the rights they need. *)
module Request = Request

(** Database contexts: a label, a held connection, or a transaction. Built
    by a pool ({!Pools_sig.Sig}). *)
module Ctx : module type of struct
    include Ctx
  end
  with module Internal := Ctx.Internal

(** Error types and exceptions raised by query helpers. *)
module Error = Error

(** {1 Pools} *)

(** The main pool functor. Apply [Pools.Make(Config)] to obtain a
    database module for one pool family; the driver libraries
    ([Veins_mariadb.Pools.Make], [Veins_postgresql.Pools.Make]) need only
    the database. *)
module Pools = Pools

(** Module-type signatures for the pool functor: its configuration and what
    it returns (pool lifecycle, contexts, statements). *)
module Pools_sig = Pools_sig

(** Pools for one database user: no roles, logins or needs. *)
module Plain : module type of struct
  include Plain
end

(** SQL dialect implementations (MariaDB / PostgreSQL DDL differences). *)
module Dialect = Dialect

(** {1 Building requests} *)

(** Caqti row types with custom encoders and decoders, written as lists. *)
module Caqti_encoders = Caqti_encoders

(** Parameters of a statement whose number is only known at runtime. *)
module Dynparam = Dynparam

(** {1 Migrations} *)

(** Standalone migration module.  Types and registry at the top level;
    apply [Migration.Make(Db)] to get a runner for a specific pool. *)
module Migration = Migration

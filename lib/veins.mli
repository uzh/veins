(** Veins — database connection pooling for OCaml.

    {b Quick-start}

    {[
    (* 1. Instantiate the pool *)
    module Db = Veins_mariadb.Pools.Make (struct
        let database =
          let url = Veins.Url.create (Sys.getenv "DATABASE_URL") in
          Veins.Database.create (Veins.Label.create "root") (Veins.Database.Main url)
        ;;
      end)

    (* 2. Declare what statements need *)
    let read = Veins.Capability.create "read"

    let find_name =
      {sql| SELECT name FROM users WHERE id = ? |sql}
      |> Caqti_type.(int ->? string)
      |> Veins.Request.create ~needs:[ read ]
    ;;

    (* 3. Run them on a context *)
    let () =
      Db.Pool.initialize ();
      let root = Veins.Label.create "root" in
      Lwt_main.run
        (let%lwt name = Db.find_opt (Db.label_ctx root) find_name 1 in
         Db.transaction_ctx root (fun ctx ->
           Veins.Ctx.after_commit ctx (fun () -> print_endline "committed");
           Db.find_opt ctx find_name 2))
    ;;
    ]}

    {b Roles.} With one URL per role ([Database.Multiple]), each role is a
    database user with a set of {!Capability} values. Every context names its
    role and every statement is checked against it before it is sent. A
    single-URL database ([Database.Main]) has every capability.

    The context design ({!Ctx}) comes from Reynir Björnsson's database
    refactoring of the pool tool (uzh/z-pool-tool#647). *)

(** Opaque database label used as the key for pool lookups. *)
module Label = Entity.Label

(** Role name for a database user (e.g. ["readonly"], ["write"]).
    Distinct from {!Label} to prevent accidental mixing. *)
module Role = Entity.Role

(** A right a statement needs, defined by the application or library. *)
module Capability = Entity.Capability

(** Database connection URL.  Opaque — the raw connection string is not
    accessible after construction.  Pass the value to
    {!Database.create}. *)
module Url : sig
  type t = Entity.Url.t

  val create : string -> t
  val equal : t -> t -> bool
  val pp : Format.formatter -> t -> unit
  val show : t -> string
end

(** Connection and migration status of a database entry. *)
module Status = Entity.Status

(** Named database connection record. *)
module Database = Entity.Database

(** Dynamic query parameter accumulator for type-safe ad-hoc queries. *)
module Dynparam = Entity.Dynparam

(** Error types and exceptions raised by query helpers. *)
module Error = Error

(** Database contexts: a label, a held connection, or a transaction. *)
module Ctx = Ctx

(** Caqti requests with the capabilities they need. *)
module Request = Request

(** SQL dialect implementations (MariaDB / PostgreSQL DDL differences). *)
module Dialect = Dialect

(** Module-type signatures for the pool functor. *)
module Pools_sig = Pools_sig

(** The main pool functor. Apply [Pools.Make(Config)] to obtain a
    database module for one pool family. *)
module Pools = Pools

(** Standalone migration module.  Types and registry at the top level;
    apply [Migration.Make(Db)] to get a runner for a specific pool. *)
module Migration = Migration

(** Global in-process registry of named {!Database.t} entries. *)
module Databases = Databases

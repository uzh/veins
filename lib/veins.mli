(** Veins — database connection pooling for OCaml.

    {b Quick-start}

    {[
    (* 1. Define a config module *)
    module Cfg = struct
      let database =
        let url = Veins.Url.create (Sys.getenv "DATABASE_URL") in
        Veins.Database.create (Veins.Label.create "root") url
      ;;

      let database_pool_size = 10
      let expected_databases = 1

      module Dialect = Veins.Dialect.Mariadb
    end

    (* 2. Instantiate the pool *)
    module Db = Veins.Pools.Make (Cfg)

    (* 3. Instantiate the migration runner *)
    module M = Veins.Migration.Make (Db)

    (* 4. Register migrations (at module init time) *)
    let () =
      let open Veins.Migration in
      register
        ~for_databases:Migration.All
        (create
           (Namespace.create "my_app")
           ~written_at:(ptime_of_string "2024-01-15T10:00:00Z")
         |> add_step
              (Step.create
                 ~id:(Id.create "550e8400-e29b-41d4-a716-446655440001")
                 ~label:"create users table"
                 ~down:"DROP TABLE IF EXISTS users"
                 {|CREATE TABLE IF NOT EXISTS users (
                        id   INT          PRIMARY KEY AUTO_INCREMENT,
                        name VARCHAR(255) NOT NULL
                      )|})
        )
    ;;

    (* 5. Initialize pool and run migrations *)
    let () =
      let root = Veins.Label.create "root" in
      Db.Pool.initialize ();
      Lwt_main.run
        (match%lwt M.run_all root () with
         | Ok () -> Lwt.return_unit
         | Error e -> failwith (Veins.Error.show e))
    ;;
    ]} *)

(** Opaque database label used as the key for pool lookups. *)
module Label = Entity.Label

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

(** Error types and exception raised by query helpers. *)
module Error = Error

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

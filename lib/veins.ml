(** Veins — database connection pooling for OCaml.

    {b Quick-start}

    {[
      (* 1. Define a config module *)
      module Cfg = struct
        let database =
          let url = Veins.Url.create (Sys.getenv "DATABASE_URL") in
          Veins.Database.create (Veins.Label.create "root") url
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
        Veins.Migration.register
          ~for_database:(Veins.Label.create "root")
          Veins.Migration.(
            empty "my_app"
            |> add_step
                 (step
                    ~id:"550e8400-e29b-41d4-a716-446655440001"
                    ~label:"create users table"
                    ~down:"DROP TABLE IF EXISTS users"
                    {|CREATE TABLE IF NOT EXISTS users (
                        id   INT          PRIMARY KEY AUTO_INCREMENT,
                        name VARCHAR(255) NOT NULL
                      )|})
          )

      (* 5. Initialize pool and run migrations *)
      let () =
        let root = Veins.Label.create "root" in
        Db.Pool.initialize ();
        Lwt_main.run
          (match%lwt M.run_all root () with
           | Ok () -> Lwt.return_unit
           | Error e -> failwith (Veins.Error.show e))
    ]}
*)

(** Include core domain types (labels, URLs, statuses). *)
include Entity

(** Error types and exception used throughout the library. *)
module Error = Error

(** SQL dialect implementations (MariaDB / PostgreSQL DDL differences). *)
module Dialect = Dialect

(** Module-type signatures for the pool functor. *)
module Pools_sig = Pools_sig

(** The main pool functor.  Apply [Pools.Make(Config)] to obtain a fully
    featured database module for one pool family. *)
module Pools = Pools

(** Standalone migration module.  Types and registry at the top level;
    apply [Migration.Make(Db)] to get a runner for a specific pool. *)
module Migration = Migration

(** Global in-process registry of named {!Database.t} entries.
    Register databases at startup, retrieve them by label anywhere. *)
module Databases = Databases

(** Vena — database connection pooling for OCaml.

    {b Quick-start}

    {[
      (* 1. Define a config module *)
      module Cfg = struct
        let database =
          Vena.Entity.(create root (Url.create (Sys.getenv "DATABASE_URL")))
        let database_pool_size = 10
        let expected_databases = 1
        module Dialect = Vena.Dialect.Mariadb
      end

      (* 2. Instantiate the pool *)
      module Db = Vena.Pools.Make (Cfg)

      (* 3. Instantiate the migration runner *)
      module M = Vena.Migration.Make (Db)

      (* 4. Register migrations (at module init time) *)
      let () =
        Vena.Migration.register
          ~for_database:Vena.Entity.root
          Vena.Migration.(
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
        Db.Pool.initialize ();
        Lwt_main.run
          (match%lwt M.run_all Vena.Entity.root () with
           | Ok () -> Lwt.return_unit
           | Error e -> failwith (Vena.Error.show e))
    ]}
*)

(** Core domain types (labels, URLs, statuses). *)
module Entity = Entity

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

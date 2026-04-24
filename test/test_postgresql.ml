(** Integration tests against a live PostgreSQL instance.

    Environment variables (all optional, fall back to Docker-compose defaults):
    - [POSTGRES_URL]  e.g. [postgresql://root:root@database-postgres/development]
*)

open Vena

let default_url = "postgresql://root:root@database-postgres/development"

module PostgresDb = Pools.Make (struct
  let database =
    Test_helpers.db_of_env_or "POSTGRES_URL" default_url
  ;;

  let database_pool_size = 5
  let expected_databases = 1

  module Dialect = Dialect.Postgresql
end)

module MigPostgres = Migration.Make (PostgresDb)

let setup () =
  PostgresDb.Pool.initialize ();
  match PostgresDb.Pool.connect Entity.root with
  | Ok () -> ()
  | Error e -> failwith (Error.show e)
;;

let test_ping () =
  let%lwt result = PostgresDb.find Entity.root Test_helpers.ping_request () in
  assert (result = 1);
  Lwt.return_unit
;;

let test_roundtrip () = Test_helpers.roundtrip_test (module PostgresDb) ()
let test_transaction () = Test_helpers.transaction_test (module PostgresDb) ()
let test_rollback () = Test_helpers.rollback_test (module PostgresDb) ()
let test_migration () = Test_helpers.migration_test (module PostgresDb) (module MigPostgres) ()

let test_multi_pool () =
  (* Second pool with its own label pointing to the same DB *)
  let alt_url = default_url in
  let alt_db =
    Entity.(create (Label.create "pg_alt") (Url.create alt_url))
  in
  PostgresDb.Pool.add alt_db;
  let alt_label = Entity.Label.create "pg_alt" in
  let%lwt result = PostgresDb.find alt_label Test_helpers.ping_request () in
  assert (result = 1);
  let%lwt () = PostgresDb.Pool.drop alt_label in
  Lwt.return_unit
;;

let () =
  setup ();
  let open Alcotest_lwt in
  Lwt_main.run
  @@ run "Vena PostgreSQL"
       [ ( "connectivity"
         , [ test_case "ping" `Quick (fun _ () -> test_ping ())
           ; test_case "roundtrip" `Quick (fun _ () -> test_roundtrip ())
           ; test_case "multi_pool" `Quick (fun _ () -> test_multi_pool ())
           ] )
       ; ( "transactions"
         , [ test_case "commit" `Quick (fun _ () -> test_transaction ())
           ; test_case "rollback" `Quick (fun _ () -> test_rollback ())
           ] )
       ; ( "migrations"
         , [ test_case "run_all" `Quick (fun _ () -> test_migration ()) ] )
       ]
;;

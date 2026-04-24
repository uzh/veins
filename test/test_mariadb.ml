(** Integration tests against a live MariaDB instance.

    Environment variables (all optional, fall back to Docker-compose defaults):
    - [MARIADB_URL]  e.g. [mariadb://admin:password@database-mariadb/development]
*)

open Vena

let default_url = "mariadb://admin:password@database-mariadb/development"

module MariaDb = Pools.Make (struct
  let database =
    Test_helpers.db_of_env_or "MARIADB_URL" default_url
  ;;

  let database_pool_size = 5
  let expected_databases = 1

  module Dialect = Dialect.Mariadb
end)

module MigMariaDb = Migration.Make (MariaDb)

let setup () =
  MariaDb.Pool.initialize ();
  match MariaDb.Pool.connect Entity.root with
  | Ok () -> ()
  | Error e -> failwith (Error.show e)
;;

let test_ping () =
  let%lwt result = MariaDb.find Entity.root Test_helpers.ping_request () in
  assert (result = 1);
  Lwt.return_unit
;;

let test_roundtrip () = Test_helpers.roundtrip_test (module MariaDb) ()
let test_transaction () = Test_helpers.transaction_test (module MariaDb) ()
let test_rollback () = Test_helpers.rollback_test (module MariaDb) ()
let test_migration () = Test_helpers.migration_test (module MariaDb) (module MigMariaDb) ()

let test_pool_add_and_drop () =
  let extra_url = default_url in
  let extra_db =
    Entity.(create (Label.create "mariadb_extra") (Url.create extra_url))
  in
  MariaDb.Pool.add extra_db;
  let%lwt () = MariaDb.Pool.drop (Entity.Label.create "mariadb_extra") in
  Lwt.return_unit
;;

let () =
  setup ();
  let open Alcotest_lwt in
  Lwt_main.run
  @@ run "Vena MariaDB"
       [ ( "connectivity"
         , [ test_case "ping" `Quick (fun _ () -> test_ping ())
           ; test_case "roundtrip" `Quick (fun _ () -> test_roundtrip ())
           ; test_case "pool_add_drop" `Quick (fun _ () -> test_pool_add_and_drop ())
           ] )
       ; ( "transactions"
         , [ test_case "commit" `Quick (fun _ () -> test_transaction ())
           ; test_case "rollback" `Quick (fun _ () -> test_rollback ())
           ] )
       ; ( "migrations"
         , [ test_case "run_all" `Quick (fun _ () -> test_migration ()) ] )
       ]
;;

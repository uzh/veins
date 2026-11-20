(* One request, SQL per dialect: veins' requests render their SQL from the
   dialect of the connection they run on. The dialects are built with Caqti's
   driver-private constructors, so this runs without a database. *)

open Veins

let[@alert "-caqti_private"] mariadb =
  Caqti.Template.Dialect.create_mysql
    ~server_version:(Caqti.Template.Version.of_string_unsafe "10.6")
    ()
;;

let[@alert "-caqti_private"] postgresql =
  Caqti.Template.Dialect.create_pgsql
    ~server_version:(Caqti.Template.Version.of_string_unsafe "17")
    ~client_library:`postgresql
    ()
;;

let[@alert "-caqti_private"] printing =
  Caqti.Template.Dialect.create_unknown ~purpose:`Printing ()
;;

let render request dialect =
  Caqti.Template.Request.queries request dialect
  |> CCList.map Caqti.Template.Query.show
  |> CCString.concat "; "
;;

let contains ~sub s = CCString.mem ~sub s

let test_kind () =
  Alcotest.(check bool) "MariaDB" true (Dialect.kind mariadb = Dialect.Mariadb);
  Alcotest.(check bool) "PostgreSQL" true (Dialect.kind postgresql = Dialect.Postgresql);
  Alcotest.(check bool)
    "printing renders MariaDB's"
    true
    (Dialect.kind printing = Dialect.Mariadb)
;;

let test_one_request_per_dialect () =
  let request =
    Dialect.request
      Caqti.Template.Request.Static
      Caqti.Templater.T.(string -->. unit)
      (Dialect.upsert_step_row ~table:"t")
  in
  let on_mariadb = render request mariadb in
  let on_postgresql = render request postgresql in
  Alcotest.(check bool) ("MariaDB: " ^ on_mariadb) true (contains ~sub:"UNHEX" on_mariadb);
  Alcotest.(check bool)
    ("PostgreSQL: " ^ on_postgresql)
    true
    (contains ~sub:"::uuid" on_postgresql);
  (* rendering for logs must not fail *)
  Alcotest.(check bool) "printing" true (contains ~sub:"UNHEX" (render request printing))
;;

let test_session_sql () =
  Alcotest.(check bool)
    "UTC on MariaDB"
    true
    (contains ~sub:"time_zone" (Dialect.set_utc Dialect.Mariadb));
  Alcotest.(check bool)
    "UTC on PostgreSQL"
    true
    (contains ~sub:"TIME ZONE" (Dialect.set_utc Dialect.Postgresql));
  Alcotest.(check (option string))
    "autocommit restored on MariaDB"
    (Some "SET autocommit = 1")
    (Dialect.restore_autocommit Dialect.Mariadb);
  Alcotest.(check (option string))
    "nothing to restore on PostgreSQL"
    None
    (Dialect.restore_autocommit Dialect.Postgresql);
  Alcotest.(check (option string))
    "no FK toggle on PostgreSQL"
    None
    (Dialect.set_fk_checks Dialect.Postgresql false)
;;

let test_identifiers () =
  CCList.iter
    (fun name -> Alcotest.(check bool) name true (Dialect.is_identifier name))
    [ "veins_migration_state"; "_t"; "T1" ];
  CCList.iter
    (fun name -> Alcotest.(check bool) name false (Dialect.is_identifier name))
    [ ""; "1t"; "a b"; "t; DROP TABLE x"; "a.b"; "t`"; CCString.make 65 'a' ]
;;

let test_tables () =
  Alcotest.(check string)
    "truncate on MariaDB"
    "TRUNCATE TABLE t"
    (Dialect.truncate Dialect.Mariadb ~table:"t");
  Alcotest.(check string)
    "truncate on PostgreSQL"
    "TRUNCATE TABLE t CASCADE"
    (Dialect.truncate Dialect.Postgresql ~table:"t");
  Alcotest.(check string)
    "drop on MariaDB"
    "DROP TABLE IF EXISTS t"
    (Dialect.drop Dialect.Mariadb ~table:"t");
  Alcotest.(check string)
    "drop on PostgreSQL"
    "DROP TABLE IF EXISTS t CASCADE"
    (Dialect.drop Dialect.Postgresql ~table:"t");
  let on_mariadb = Dialect.list_tables Dialect.Mariadb in
  let on_postgresql = Dialect.list_tables Dialect.Postgresql in
  Alcotest.(check bool)
    ("list on MariaDB: " ^ on_mariadb)
    true
    (contains ~sub:"table_schema = DATABASE()" on_mariadb
     && contains ~sub:"table_type = 'BASE TABLE'" on_mariadb);
  Alcotest.(check bool)
    ("list on PostgreSQL: " ^ on_postgresql)
    true
    (contains ~sub:"table_schema = ANY (current_schemas(false))" on_postgresql
     && contains ~sub:"table_type = 'BASE TABLE'" on_postgresql
     && not (contains ~sub:"DATABASE()" on_postgresql));
  let request =
    Dialect.request
      Caqti.Template.Request.Direct
      Caqti.Templater.T.(unit -->. unit)
      (Dialect.truncate ~table:"t")
  in
  Alcotest.(check bool)
    "CASCADE only on PostgreSQL"
    true
    (contains ~sub:"CASCADE" (render request postgresql)
     && (not (contains ~sub:"CASCADE" (render request mariadb)))
     && not (contains ~sub:"CASCADE" (render request printing)))
;;

let () =
  Alcotest.run
    "Veins Dialect"
    [ ( "dialect"
      , [ Alcotest.test_case "kind" `Quick test_kind
        ; Alcotest.test_case
            "one request, SQL per dialect"
            `Quick
            test_one_request_per_dialect
        ; Alcotest.test_case "session SQL" `Quick test_session_sql
        ; Alcotest.test_case "identifiers" `Quick test_identifiers
        ; Alcotest.test_case "tables" `Quick test_tables
        ] )
    ]
;;

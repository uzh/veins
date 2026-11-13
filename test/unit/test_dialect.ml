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
      (Dialect.delete_applied_step ~table:"t")
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
        ] )
    ]
;;

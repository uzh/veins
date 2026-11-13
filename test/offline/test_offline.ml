(* Pool behaviour that needs no database: a fake server stands in for one
   that went away, and counts the connections it got. Whether a statement
   fits its role is checked by the compiler, see test/typing. *)

open Veins
module T = Caqti.Templater.T

module Db = Pools.Make (struct
    let database =
      Database.create (Label.create "unused") (Url.create "mariadb://unused/x")
    ;;

    let database_pool_size = 5
    let expected_databases = 4

    module Dialect = Veins_mariadb.Dialect
  end)

let ping =
  Caqti.Templater.static T.(unit -->! int) "SELECT 1" |> Request.create ~needs:Roles.read
;;

let owner_ctx label = Db.label_ctx ~role:Role.owner label

let with_server f =
  let%lwt server = Net.Unresponsive.start () in
  Lwt.finalize (fun () -> f server) (fun () -> Net.Unresponsive.stop server)
;;

let url server = Url.create (Net.Unresponsive.url server ~scheme:"mariadb")

let expect name f check =
  match%lwt f () with
  | (_ : _) -> Alcotest.failf "%s: expected an exception" name
  | exception exn -> Lwt.return (check exn)
;;

(* Every failing query disconnects its pool, and disconnecting drains it.
   Caqti's [Pool.drain] wakes a single waiter once the pool runs empty, so two
   drains of the same pool left one of them, and the query behind it, pending
   forever (pool tool #637). *)
let test_unreachable_database_settles_every_query () =
  with_server
  @@ fun server ->
  let label = Label.create "veins_unreachable" in
  Db.Pool.add (Database.create label (url server));
  let query () =
    Lwt.catch
      (fun () -> Db.find (owner_ctx label) ping () |> Lwt.map (fun (_ : int) -> ()))
      (fun (_ : exn) -> Lwt.return_unit)
  in
  let queries = CCList.init 5 (fun (_ : int) -> query ()) in
  let%lwt settled =
    Lwt.pick
      [ Lwt.join queries |> Lwt.map (fun () -> true)
      ; Lwt_unix.sleep 30.0 |> Lwt.map (fun () -> false)
      ]
  in
  let pending = CCList.count (fun query -> Lwt.state query = Lwt.Sleep) queries in
  Db.Pool.drop label;
  Alcotest.(check int) "no query is left pending" 0 pending;
  Lwt.return (Alcotest.(check bool) "every failing query settles" true settled)
;;

(* A pool that failed must try again on the next call (pool tool #624). *)
let test_failed_pool_retries () =
  with_server
  @@ fun server ->
  let label = Label.create "veins_retry" in
  Db.Pool.add (Database.create label (url server));
  let attempt () =
    Lwt.catch
      (fun () -> Db.find (owner_ctx label) ping () |> Lwt.map (fun (_ : int) -> ()))
      (fun (_ : exn) -> Lwt.return_unit)
  in
  let%lwt () = attempt () in
  let%lwt () = attempt () in
  let after_two = server.Net.Unresponsive.accepted in
  let%lwt () = attempt () in
  let%lwt () = attempt () in
  Db.Pool.drop label;
  Lwt.return
    (Alcotest.(check bool)
       "later calls still reach the server"
       true
       (server.Net.Unresponsive.accepted > after_two))
;;

(* Without a URL of its own, a login connects with the owner's pool: a
   database with a single user needs nothing but its URL. *)
let test_logins_share_the_owner_pool () =
  with_server
  @@ fun server ->
  let label = Label.create "veins_single" in
  Db.Pool.add (Database.create label (url server));
  let%lwt owner_pool = Db.Pool.fetch label in
  let%lwt reader_pool = Db.Pool.fetch ~login:Roles.reader_login label in
  Alcotest.(check bool) "same pool" true (owner_pool == reader_pool);
  let%lwt () =
    expect
      "reader on the owner's URL"
      (fun () -> Db.find (Db.label_ctx ~role:Roles.reader label) ping ())
      (function
        | Error.Failed { Error.login; role; _ } ->
          Alcotest.(check string) "login" "owner" (Login.name login);
          Alcotest.(check (option string)) "role" (Some "reader") role
        | exn -> Alcotest.failf "expected Failed, got %s" (Printexc.to_string exn))
  in
  Db.Pool.drop label;
  Lwt.return
    (Alcotest.(check bool)
       "sent to the owner's URL"
       true
       (server.Net.Unresponsive.accepted > 0))
;;

let test_registry () =
  with_server
  @@ fun server ->
  let label = Label.create "veins_logins" in
  Db.Pool.add
    (Database.create
       ~logins:[ Roles.reader_login, url server; Roles.writer_login, url server ]
       label
       (url server));
  Alcotest.(check bool)
    "database with logins is listed"
    true
    (CCList.exists
       (fun db -> Label.equal (Database.label db) label)
       (Db.Pool.find_all ()));
  let%lwt owner_pool = Db.Pool.fetch label in
  let%lwt reader_pool = Db.Pool.fetch ~login:Roles.reader_login label in
  let%lwt writer_pool = Db.Pool.fetch ~login:Roles.writer_login label in
  let%lwt migrator_pool = Db.Pool.fetch ~login:Roles.migrator_login label in
  Alcotest.(check bool) "one pool per login" true (reader_pool != writer_pool);
  Alcotest.(check bool) "apart from the owner's" true (reader_pool != owner_pool);
  Alcotest.(check bool)
    "a login without URL: the owner's"
    true
    (migrator_pool == owner_pool);
  (* adding the label again is skipped, the pools stay *)
  Db.Pool.add (Database.create label (Url.create "mariadb://other/x"));
  Alcotest.(check int)
    "kept the first registration"
    2
    (Db.Pool.find label |> Option.get |> Database.logins |> CCList.length);
  let%lwt reader_pool' = Db.Pool.fetch ~login:Roles.reader_login label in
  Alcotest.(check bool) "same pool" true (reader_pool == reader_pool');
  Db.Pool.drop label;
  Alcotest.(check bool) "dropped" true (Option.is_none (Db.Pool.find label));
  expect
    "dropped label"
    (fun () -> Db.Pool.fetch ~login:Roles.reader_login label)
    (function
      | Error.Exn (Error.Database_not_registered _) -> ()
      | exn -> Alcotest.failf "dropped label: unexpected %s" (Printexc.to_string exn))
;;

let test_mariadb_permission_errors () =
  let error errno =
    Caqti.Error.request_failed
      ~uri:(Uri.of_string "mariadb://x/y")
      ~query:"INSERT INTO t VALUES (1)"
      (Caqti_driver_mariadb.Error_msg { errno; error = "denied" })
  in
  let is_permission errno = Veins_mariadb.Dialect.is_permission_error (error errno) in
  let is_connection errno = Veins_mariadb.Dialect.is_connection_error (error errno) in
  CCList.iter
    (fun errno ->
       Alcotest.(check bool)
         (Format.asprintf "%d is a permission error" errno)
         true
         (is_permission errno);
       Alcotest.(check bool)
         (Format.asprintf "%d keeps the pool" errno)
         false
         (is_connection errno))
    [ 1044; 1142; 1143; 1227; 1370 ];
  CCList.iter
    (fun errno ->
       Alcotest.(check bool)
         (Format.asprintf "%d is not a permission error" errno)
         false
         (is_permission errno))
    [ 1062; 1146; 2013 ];
  Lwt.return_unit
;;

let () =
  let open Alcotest_lwt in
  let case name speed f = test_case name speed (fun (_ : Lwt_switch.t) () -> f ()) in
  Lwt_main.run
  @@ run
       "Veins offline"
       [ ( "resilience"
         , [ case
               "unreachable database settles every query"
               `Slow
               test_unreachable_database_settles_every_query
           ; case "failed pool retries" `Quick test_failed_pool_retries
           ] )
       ; ( "logins"
         , [ case "logins share the owner's pool" `Quick test_logins_share_the_owner_pool
           ; case "registry" `Quick test_registry
           ; case "MariaDB permission errors" `Quick test_mariadb_permission_errors
           ] )
       ]
;;

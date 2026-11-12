(* Pool behaviour that needs no database: a fake server stands in for one
   that went away, and counts the connections it got, so the role checks can
   prove that a refused statement never reached the server. *)

open Veins
open Caqti_request.Infix

module Db = Pools.Make (struct
    let database =
      Database.create
        (Label.create "unused")
        (Database.Main (Url.create "mariadb://unused/x"))
    ;;

    let database_pool_size = 5
    let expected_databases = 4

    module Dialect = Veins_mariadb.Dialect
  end)

let ping =
  (Caqti_type.unit ->! Caqti_type.int) "SELECT 1" |> Request.create ~needs:[ Caps.read ]
;;

let insert =
  (Caqti_type.int ->. Caqti_type.unit) "INSERT INTO t (id) VALUES (?)"
  |> Request.create ~needs:[ Caps.write ]
;;

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

let expect_error name expected f =
  expect name f (function
    | Error.Exn error when expected error -> ()
    | exn -> Alcotest.failf "%s: unexpected %s" name (Printexc.to_string exn))
;;

let insufficient = function
  | Error.Insufficient_capabilities
      { missing = [ "test_write" ]; role = Some "reader"; _ } -> true
  | _ -> false
;;

let role_required = function
  | Error.Role_required _ -> true
  | _ -> false
;;

let role_not_configured = function
  | Error.Role_not_configured _ -> true
  | _ -> false
;;

(* Every failing query disconnects its pool, and disconnecting drains it.
   Caqti's [Pool.drain] wakes a single waiter once the pool runs empty, so two
   drains of the same pool left one of them, and the query behind it, pending
   forever (pool tool #637). *)
let test_unreachable_database_settles_every_query () =
  with_server
  @@ fun server ->
  let label = Label.create "veins_unreachable" in
  Db.Pool.add (Database.create label (Database.Main (url server)));
  let query () =
    Lwt.catch
      (fun () -> Db.find (Db.label_ctx label) ping () |> Lwt.map (fun (_ : int) -> ()))
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
  Db.Pool.add (Database.create label (Database.Main (url server)));
  let attempt () =
    Lwt.catch
      (fun () -> Db.find (Db.label_ctx label) ping () |> Lwt.map (fun (_ : int) -> ()))
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

let multiple server =
  Database.create
    (Label.create "veins_roles_offline")
    (Database.Multiple [ Caps.reader, url server; Caps.writer, url server ])
;;

let test_refused_statements_are_not_sent () =
  with_server
  @@ fun server ->
  let database = multiple server in
  let label = Database.label database in
  Db.Pool.add database;
  let%lwt () =
    expect_error "reader writes" insufficient (fun () ->
      Db.exec (Db.label_ctx ~role:Caps.reader label) insert 1)
  in
  let%lwt () =
    expect_error "raw query" insufficient (fun () ->
      Db.query ~needs:[ Caps.write ] (Db.label_ctx ~role:Caps.reader label) (fun _ ->
        Lwt_result.return ()))
  in
  let%lwt () =
    expect_error "no role" role_required (fun () -> Db.find (Db.label_ctx label) ping ())
  in
  let%lwt () =
    expect_error "no role, held connection" role_required (fun () ->
      Db.connection_ctx label (fun ctx -> Db.find ctx ping ()))
  in
  let%lwt () =
    expect_error "no role, transaction" role_required (fun () ->
      Db.transaction_ctx label (fun ctx -> Db.find ctx ping ()))
  in
  let%lwt () =
    expect_error "unknown role" role_not_configured (fun () ->
      Db.find (Db.label_ctx ~role:(Role.create "admin") label) ping ())
  in
  Db.Pool.drop label;
  Lwt.return
    (Alcotest.(check int)
       "no connection reached the server"
       0
       server.Net.Unresponsive.accepted)
;;

let test_main_role_policy () =
  with_server
  @@ fun server ->
  let strict =
    Database.create
      ~role_policy:Database.Strict
      (Label.create "veins_strict")
      (Database.Main (url server))
  in
  let fallback =
    Database.create (Label.create "veins_fallback") (Database.Main (url server))
  in
  Db.Pool.add strict;
  Db.Pool.add fallback;
  let%lwt () =
    expect_error "strict" role_not_configured (fun () ->
      Db.find (Db.label_ctx ~role:Caps.reader (Database.label strict)) ping ())
  in
  Alcotest.(check int) "strict: not sent" 0 server.Net.Unresponsive.accepted;
  (* a single-URL database has every capability, also for a named role *)
  let%lwt () =
    expect
      "fallback"
      (fun () ->
         Db.exec (Db.label_ctx ~role:Caps.reader (Database.label fallback)) insert 1)
      (function
        | Error.Failed _ -> ()
        | exn ->
          Alcotest.failf "fallback: expected Failed, got %s" (Printexc.to_string exn))
  in
  Db.Pool.drop (Database.label strict);
  Db.Pool.drop (Database.label fallback);
  Lwt.return
    (Alcotest.(check bool) "fallback: sent" true (server.Net.Unresponsive.accepted > 0))
;;

let test_registry () =
  with_server
  @@ fun server ->
  let database = multiple server in
  let label = Database.label database in
  Db.Pool.add database;
  Alcotest.(check bool)
    "role-based database is listed"
    true
    (CCList.exists
       (fun db -> Label.equal (Database.label db) label)
       (Db.Pool.find_all ()));
  let%lwt reader_pool = Db.Pool.fetch ~role:Caps.reader label in
  let%lwt writer_pool = Db.Pool.fetch ~role:Caps.writer label in
  Alcotest.(check bool) "one pool per role" true (reader_pool != writer_pool);
  (* adding the label again is skipped, the pools stay *)
  Db.Pool.add
    (Database.create
       label
       (Database.Multiple [ Caps.reader, Url.create "mariadb://other/x" ]));
  Alcotest.(check int)
    "kept the first registration"
    2
    (Db.Pool.find label |> Option.get |> Database.roles |> CCList.length);
  let%lwt reader_pool' = Db.Pool.fetch ~role:Caps.reader label in
  Alcotest.(check bool) "same pool" true (reader_pool == reader_pool');
  Db.Pool.drop label;
  Alcotest.(check bool) "dropped" true (Option.is_none (Db.Pool.find label));
  expect_error
    "dropped label"
    (function
      | Error.Database_not_registered _ -> true
      | _ -> false)
    (fun () -> Db.Pool.fetch ~role:Caps.reader label)
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
       ; ( "roles"
         , [ case
               "refused statements are not sent"
               `Quick
               test_refused_statements_are_not_sent
           ; case "main role policy" `Quick test_main_role_policy
           ; case "registry" `Quick test_registry
           ] )
       ]
;;

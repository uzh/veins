(** Shared test helpers for both MariaDB and PostgreSQL integration tests. *)

open Veins
open Caqti_request.Infix

(** Build a [Database.t] from an environment variable, falling back to [default].*)
let db_of_env_or var default =
  let raw =
    match Sys.getenv_opt var with
    | Some s when s <> "" -> s
    | _ -> default
  in
  Database.(create (Label.create "root") (Url.create raw))
;;

(** Simple query: return [1] from the database to verify connectivity. *)
let ping_request =
  let open Caqti_request.Infix in
  Caqti_type.(unit ->! int) "SELECT 1"
;;

(** Create a trivial test table, insert a row, query it back, then drop it. *)
let roundtrip_test (module Db : Pools_sig.Sig) () =
  let label = Label.create "root" in
  (* Create table *)
  let create_req =
    Caqti_type.(unit ->. unit)
      ~oneshot:true
      {|CREATE TABLE IF NOT EXISTS vena_test_roundtrip (
          id   INTEGER PRIMARY KEY,
          name VARCHAR(64) NOT NULL
        )|}
  in
  let insert_req =
    Caqti_type.(t2 int string ->. unit)
      ~oneshot:true
      {|INSERT INTO vena_test_roundtrip (id, name) VALUES (?, ?)|}
  in
  let select_req =
    Caqti_type.(unit ->* t2 int string)
      ~oneshot:true
      {|SELECT id, name FROM vena_test_roundtrip ORDER BY id|}
  in
  let drop_req =
    Caqti_type.(unit ->. unit) ~oneshot:true {|DROP TABLE IF EXISTS vena_test_roundtrip|}
  in
  let%lwt () = Db.exec label create_req () in
  let%lwt () = Db.exec label insert_req (1, "alice") in
  let%lwt () = Db.exec label insert_req (2, "bob") in
  let%lwt rows = Db.collect label select_req () in
  let%lwt () = Db.exec label drop_req () in
  assert (rows = [ 1, "alice"; 2, "bob" ]);
  Lwt.return_unit
;;

(** Insert two rows, then read them back inside a transaction. *)
let transaction_test (module Db : Pools_sig.Sig) () =
  let label = Label.create "root" in
  let create_req =
    Caqti_type.(unit ->. unit)
      ~oneshot:true
      {|CREATE TABLE IF NOT EXISTS vena_test_tx (
          id   INTEGER PRIMARY KEY,
          val  INTEGER NOT NULL
        )|}
  in
  let insert_req =
    Caqti_type.(t2 int int ->. unit)
      ~oneshot:true
      {|INSERT INTO vena_test_tx (id, val) VALUES (?, ?)|}
  in
  let select_req =
    Caqti_type.(unit ->* int) ~oneshot:true {|SELECT val FROM vena_test_tx ORDER BY id|}
  in
  let drop_req =
    Caqti_type.(unit ->. unit) ~oneshot:true {|DROP TABLE IF EXISTS vena_test_tx|}
  in
  let%lwt () = Db.exec label create_req () in
  let%lwt () =
    Db.transaction label (fun conn ->
      let module C = (val conn : Caqti_lwt.CONNECTION) in
      let open Lwt_result.Infix in
      C.exec insert_req (10, 100) >>= fun () -> C.exec insert_req (20, 200))
  in
  let%lwt vals = Db.collect label select_req () in
  let%lwt () = Db.exec label drop_req () in
  assert (vals = [ 100; 200 ]);
  Lwt.return_unit
;;

(** Verify that a failed transaction is rolled back. *)
let rollback_test (module Db : Pools_sig.Sig) () =
  let label = Label.create "root" in
  let create_req =
    Caqti_type.(unit ->. unit)
      ~oneshot:true
      {|CREATE TABLE IF NOT EXISTS vena_test_rb (
          id  INTEGER PRIMARY KEY,
          val INTEGER NOT NULL
        )|}
  in
  let insert_req =
    Caqti_type.(t2 int int ->. unit)
      ~oneshot:true
      {|INSERT INTO vena_test_rb (id, val) VALUES (?, ?)|}
  in
  let count_req =
    Caqti_type.(unit ->! int) ~oneshot:true {|SELECT COUNT(*) FROM vena_test_rb|}
  in
  let drop_req =
    Caqti_type.(unit ->. unit) ~oneshot:true {|DROP TABLE IF EXISTS vena_test_rb|}
  in
  let%lwt () = Db.exec label create_req () in
  (* This transaction intentionally fails mid-way. *)
  (try%lwt
     Db.transaction label (fun conn ->
       let module C = (val conn : Caqti_lwt.CONNECTION) in
       let open Lwt_result.Infix in
       C.exec insert_req (1, 1) >>= fun () -> Lwt.fail (Failure "forced failure"))
   with
   | _ -> Lwt.return_unit);%lwt
  let%lwt count = Db.find label count_req () in
  let%lwt () = Db.exec label drop_req () in
  assert (count = 0);
  Lwt.return_unit
;;

(** Register a two-step migration, run it, verify the state, test down. *)
let migration_test (module Db : Pools_sig.Sig) (module M : Migration.RunnerSig) () =
  let label = Label.create "root" in
  let ns =
    Migration.Namespace.create ("vena_test_mig_" ^ string_of_int (Random.int 100000))
  in
  (* Drop leftover tables so we always start from a clean slate. *)
  let drop_state =
    Caqti_type.(unit ->. unit) ~oneshot:true "DROP TABLE IF EXISTS vena_migration_state"
  in
  let drop_tbl =
    Caqti_type.(unit ->. unit) ~oneshot:true "DROP TABLE IF EXISTS vena_test_mig_tbl"
  in
  let%lwt () = Db.exec label drop_state () in
  let%lwt () = Db.exec label drop_tbl () in
  let mig =
    Migration.(
      empty ns ~written_at:(Migration.ptime_of_string "2024-01-01T00:00:00Z")
      |> add_step
           (step
              ~id:(Migration.Id.create "a1b2c3d4-0001-0001-0001-000000000001")
              ~label:"create table"
              ~down:"DROP TABLE IF EXISTS vena_test_mig_tbl"
              {|CREATE TABLE vena_test_mig_tbl (id INTEGER PRIMARY KEY)|})
      |> add_step
           (step
              ~id:(Migration.Id.create "a1b2c3d4-0001-0001-0001-000000000002")
              ~label:"insert row"
              ~down:"DELETE FROM vena_test_mig_tbl WHERE id = 42"
              {|INSERT INTO vena_test_mig_tbl (id) VALUES (42)|}))
  in
  Migration.register ~for_databases:(Migration.Database label) mig;
  (* Test up: both steps applied *)
  let%lwt () =
    match%lwt M.run_all label () with
    | Ok () -> Lwt.return_unit
    | Error e -> failwith (Error.show e)
  in
  let%lwt statuses = M.status label () in
  let _, applied, total =
    CCList.find (fun (n, _, _) -> Migration.Namespace.equal n ns) statuses
  in
  assert (applied = 2 && total = 2);
  (* Test idempotency: running again is a no-op *)
  let%lwt () =
    match%lwt M.run_all label () with
    | Ok () -> Lwt.return_unit
    | Error e -> failwith (Error.show e)
  in
  (* Test down: revert all steps *)
  let%lwt () =
    match%lwt M.down label mig with
    | Ok () -> Lwt.return_unit
    | Error e -> failwith ("down failed: " ^ Error.show e)
  in
  let%lwt statuses2 = M.status label () in
  let _, applied2, _ =
    CCList.find (fun (n, _, _) -> Migration.Namespace.equal n ns) statuses2
  in
  assert (applied2 = 0);
  (* Cleanup *)
  let%lwt () = Db.exec label drop_tbl () in
  Lwt.return_unit
;;

(* ------------------------------------------------------------------ *)
(* Performance helpers                                                  *)
(* ------------------------------------------------------------------ *)

(** Fire [n] concurrent pings against the pool and assert all return 1.
    Exercises pool borrowing under concurrency. *)
let concurrent_queries_test ?(n = 20) (module Db : Pools_sig.Sig) () =
  let label = Label.create "root" in
  let tasks = List.init n (fun _ -> Db.find label ping_request ()) in
  let%lwt results = Lwt.all tasks in
  assert (List.for_all (fun r -> r = 1) results);
  Lwt.return_unit
;;

(** Insert [n] rows sequentially and verify the count matches. *)
let bulk_insert_test ?(n = 100) (module Db : Pools_sig.Sig) () =
  let label = Label.create "root" in
  let create_req =
    Caqti_type.(unit ->. unit)
      ~oneshot:true
      {|CREATE TABLE IF NOT EXISTS vena_test_bulk (
          id  INTEGER PRIMARY KEY,
          val INTEGER NOT NULL
        )|}
  in
  let insert_req =
    Caqti_type.(t2 int int ->. unit)
      ~oneshot:true
      {|INSERT INTO vena_test_bulk (id, val) VALUES (?, ?)|}
  in
  let count_req =
    Caqti_type.(unit ->! int) ~oneshot:true {|SELECT COUNT(*) FROM vena_test_bulk|}
  in
  let drop_req =
    Caqti_type.(unit ->. unit) ~oneshot:true {|DROP TABLE IF EXISTS vena_test_bulk|}
  in
  let%lwt () = Db.exec label create_req () in
  let%lwt () =
    Lwt_list.iter_s (fun i -> Db.exec label insert_req (i, i * 2)) (List.init n Fun.id)
  in
  let%lwt count = Db.find label count_req () in
  let%lwt () = Db.exec label drop_req () in
  assert (count = n);
  Lwt.return_unit
;;

(* ------------------------------------------------------------------ *)
(* Resilience helpers                                                   *)
(* ------------------------------------------------------------------ *)

(** Disconnect the pool then issue a query — the pool must auto-reconnect. *)
let disconnect_reconnect_test (module Db : Pools_sig.Sig) () =
  let label = Label.create "root" in
  let%lwt () = Db.Pool.disconnect label in
  let%lwt result = Db.find label ping_request () in
  assert (result = 1);
  Lwt.return_unit
;;

(** Querying an unknown label must raise [Error.Exn (Database_not_registered _)]. *)
let unregistered_label_test (module Db : Pools_sig.Sig) () =
  let unknown = Label.create "vena_nonexistent_________label" in
  Lwt.catch
    (fun () ->
       let%lwt _ = Db.find unknown ping_request () in
       Lwt.fail_with "expected Database_not_registered but query succeeded")
    (function[@warning "-4"]
      | Error.Exn (Error.Database_not_registered _) -> Lwt.return_unit
      | exn -> Lwt.fail exn)
;;

(** Reset the pool entry for [db] then verify queries still work. *)
let pool_reset_test (module Db : Pools_sig.Sig) db () =
  let label = Label.create "root" in
  let%lwt () = Db.Pool.reset db in
  let%lwt result = Db.find label ping_request () in
  assert (result = 1);
  Lwt.return_unit
;;

(** Register two extra pools pointing to [url], disconnect them both, then
    verify each auto-reconnects independently and the primary pool is
    unaffected throughout. *)
let multi_disconnect_reconnect_test (module Db : Pools_sig.Sig) url () =
  let lbl_a = Label.create "vena_extra_a" in
  let lbl_b = Label.create "vena_extra_b" in
  let db_a = Database.create lbl_a (Url.create url) in
  let db_b = Database.create lbl_b (Url.create url) in
  Db.Pool.add db_a;
  Db.Pool.add db_b;
  (* Disconnect both extra pools *)
  let%lwt () = Db.Pool.disconnect lbl_a in
  let%lwt () = Db.Pool.disconnect lbl_b in
  (* Each should auto-reconnect on the next query *)
  let%lwt r_a = Db.find lbl_a ping_request () in
  let%lwt r_b = Db.find lbl_b ping_request () in
  assert (r_a = 1);
  assert (r_b = 1);
  (* Primary pool must still be healthy *)
  let%lwt r_root = Db.find (Label.create "root") ping_request () in
  assert (r_root = 1);
  (* Clean up *)
  let%lwt () = Db.Pool.drop lbl_a in
  let%lwt () = Db.Pool.drop lbl_b in
  Lwt.return_unit
;;

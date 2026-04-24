(** Shared test helpers for both MariaDB and PostgreSQL integration tests. *)

open Vena
open Caqti_request.Infix

(** Build an [Entity.t] from an environment variable, falling back to [default].*)
let db_of_env_or var default =
  let raw = match Sys.getenv_opt var with Some s when s <> "" -> s | _ -> default in
  Entity.(create root (Url.create raw))
;;

(** Simple query: return [1] from the database to verify connectivity. *)
let ping_request =
  let open Caqti_request.Infix in
  Caqti_type.(unit ->! int) "SELECT 1"
;;

(** Create a trivial test table, insert a row, query it back, then drop it. *)
let roundtrip_test (module Db : Pools_sig.Sig) () =
  let label = Entity.root in
  (* Create table *)
  let create_req =
    Caqti_type.(unit ->. unit) ~oneshot:true
      {|CREATE TABLE IF NOT EXISTS vena_test_roundtrip (
          id   INTEGER PRIMARY KEY,
          name VARCHAR(64) NOT NULL
        )|}
  in
  let insert_req =
    Caqti_type.(t2 int string ->. unit) ~oneshot:true
      {|INSERT INTO vena_test_roundtrip (id, name) VALUES (?, ?)|}
  in
  let select_req =
    Caqti_type.(unit ->* t2 int string) ~oneshot:true
      {|SELECT id, name FROM vena_test_roundtrip ORDER BY id|}
  in
  let drop_req =
    Caqti_type.(unit ->. unit) ~oneshot:true
      {|DROP TABLE IF EXISTS vena_test_roundtrip|}
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
  let label = Entity.root in
  let create_req =
    Caqti_type.(unit ->. unit) ~oneshot:true
      {|CREATE TABLE IF NOT EXISTS vena_test_tx (
          id   INTEGER PRIMARY KEY,
          val  INTEGER NOT NULL
        )|}
  in
  let insert_req =
    Caqti_type.(t2 int int ->. unit) ~oneshot:true
      {|INSERT INTO vena_test_tx (id, val) VALUES (?, ?)|}
  in
  let select_req =
    Caqti_type.(unit ->* int) ~oneshot:true
      {|SELECT val FROM vena_test_tx ORDER BY id|}
  in
  let drop_req =
    Caqti_type.(unit ->. unit) ~oneshot:true
      {|DROP TABLE IF EXISTS vena_test_tx|}
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
  let label = Entity.root in
  let create_req =
    Caqti_type.(unit ->. unit) ~oneshot:true
      {|CREATE TABLE IF NOT EXISTS vena_test_rb (
          id  INTEGER PRIMARY KEY,
          val INTEGER NOT NULL
        )|}
  in
  let insert_req =
    Caqti_type.(t2 int int ->. unit) ~oneshot:true
      {|INSERT INTO vena_test_rb (id, val) VALUES (?, ?)|}
  in
  let count_req =
    Caqti_type.(unit ->! int) ~oneshot:true
      {|SELECT COUNT(*) FROM vena_test_rb|}
  in
  let drop_req =
    Caqti_type.(unit ->. unit) ~oneshot:true
      {|DROP TABLE IF EXISTS vena_test_rb|}
  in
  let%lwt () = Db.exec label create_req () in
  (* This transaction intentionally fails mid-way. *)
  (try%lwt
    Db.transaction label (fun conn ->
      let module C = (val conn : Caqti_lwt.CONNECTION) in
      let open Lwt_result.Infix in
      C.exec insert_req (1, 1)
      >>= fun () -> Lwt.fail (Failure "forced failure"))
   with
   | _ -> Lwt.return_unit);%lwt
  let%lwt count = Db.find label count_req () in
  let%lwt () = Db.exec label drop_req () in
  assert (count = 0);
  Lwt.return_unit
;;

(** Register a two-step migration, run it, verify the state, test down. *)
let migration_test (module Db : Pools_sig.Sig) (module M : Migration.RunnerSig) () =
  let label = Entity.root in
  let ns = Migration.Namespace.create ("vena_test_mig_" ^ string_of_int (Random.int 100000)) in
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
              {|INSERT INTO vena_test_mig_tbl (id) VALUES (42)|})
    )
  in
  Migration.register ~for_database:label mig;
  (* Test up: both steps applied *)
  let%lwt () =
    match%lwt M.run_all label () with
    | Ok () -> Lwt.return_unit
    | Error e -> failwith (Error.show e)
  in
  let%lwt statuses = M.status label () in
  let (_, applied, total) =
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
  let (_, applied2, _) =
    CCList.find (fun (n, _, _) -> Migration.Namespace.equal n ns) statuses2
  in
  assert (applied2 = 0);
  (* Cleanup *)
  let%lwt () = Db.exec label drop_tbl () in
  Lwt.return_unit
;;

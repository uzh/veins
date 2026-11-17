(* Integration tests against a live database, shared by both dialects.

   Several tests are ported from the pool tool (UTC session, query errors
   keep the pool, clear drains, unreachable database) and from guardian's
   transaction tests (rollback, nesting, after-commit hooks). *)

open Veins

module type Dialect = sig
  module Db : Pools_sig.Sig

  (** Prefix of the environment variables, e.g. ["MARIADB"]. *)
  val env : string

  val default_url : string
  val default_port : int

  (** Offset of [NOW()] from UTC in seconds, as an int. *)
  val utc_offset_sql : string

  (** The server-side id of the current connection, as an int. *)
  val connection_id_sql : string

  (** The database user of the current connection, as a string. *)
  val current_user_sql : string

  (** The session's statement timeout in seconds, as an int. *)
  val statement_timeout_sql : string
end

let env_opt var =
  match Sys.getenv_opt var with
  | Some value when not (CCString.is_empty value) -> Some value
  | _ -> None
;;

let expect_exn name f check =
  match%lwt f () with
  | (_ : _) -> Alcotest.failf "%s: expected an exception" name
  | exception exn -> Lwt.return (check exn)
;;

let permission_denied name ~login ~needs = function
  | Error.Exn (Error.Permission_denied { login = login'; needs = needs'; _ }) ->
    Alcotest.(check string) (name ^ ": login") login login';
    Alcotest.(check (list string)) (name ^ ": needs") needs needs'
  | exn ->
    Alcotest.failf "%s: expected Permission_denied, got %s" name (Printexc.to_string exn)
;;

module Make (D : Dialect) = struct
  module T = Caqti.Templater.T

  let static = Caqti.Templater.static
  let direct = Caqti.Templater.direct

  module Db = D.Db

  let url = env_opt (D.env ^ "_URL") |> CCOption.value ~default:D.default_url
  let role_url role = env_opt (Format.asprintf "%s_%s_URL" D.env role)

  (* Every login connects as the all-rights user unless the per-role URLs are
     set; the "which user" and permission checks need them. *)
  let distinct_role_users =
    match role_url "READER" with
    | Some reader -> not (CCString.equal reader url)
    | None -> false
  ;;

  let root = Label.create "root"
  let owner = Role.owner
  let root_ctx () = Db.label_ctx ~role:owner root
  let database = Database.create root (Url.create url)
  let ping = static T.(unit -->! int) "SELECT 1" |> Request.create ~needs:Roles.read
  let int_query sql = direct T.(unit -->! int) sql |> Request.create ~needs:Roles.read

  let string_query sql =
    direct T.(unit -->! string) sql |> Request.create ~needs:Roles.read
  ;;

  let ddl sql = direct T.(unit -->. unit) sql |> Request.create ~needs:Roles.schema

  let insert table =
    direct
      T.(t2 int int -->. unit)
      (Format.asprintf "INSERT INTO %s (id, val) VALUES (?, ?)" table)
    |> Request.create ~needs:Need.(Roles.read & Roles.write)
  ;;

  let count table = int_query (Format.asprintf "SELECT COUNT(*) FROM %s" table)

  let rows table =
    direct
      T.(unit -->* t2 int int)
      (Format.asprintf "SELECT id, val FROM %s ORDER BY id" table)
    |> Request.create ~needs:Roles.read
  ;;

  let create_table table =
    ddl
      (Format.asprintf
         "CREATE TABLE %s (id INTEGER PRIMARY KEY, val INTEGER NOT NULL)"
         table)
  ;;

  let drop_table table = ddl (Format.asprintf "DROP TABLE IF EXISTS %s" table)

  let with_table ?(ctx = fun () -> root_ctx ()) name f =
    let table = "veins_t_" ^ name in
    let%lwt () = Db.exec (ctx ()) (drop_table table) () in
    let%lwt () = Db.exec (ctx ()) (create_table table) () in
    Lwt.finalize (fun () -> f table) (fun () -> Db.exec (ctx ()) (drop_table table) ())
  ;;

  let check_count table expected =
    let%lwt n = Db.find (root_ctx ()) (count table) () in
    Lwt.return (Alcotest.(check int) ("rows in " ^ table) expected n)
  ;;

  let ignore_exit f =
    Lwt.catch f (function
      | Exit -> Lwt.return_unit
      | exn -> Lwt.reraise exn)
  ;;

  (* {1 Statements} *)

  let test_roundtrip () =
    with_table "roundtrip"
    @@ fun table ->
    let ctx = root_ctx () in
    let%lwt () = Db.exec ctx (insert table) (1, 10) in
    let%lwt () =
      Db.populate
        ~needs:Roles.write
        ctx
        table
        [ "id"; "val" ]
        T.(t2 int int)
        [ 2, 20; 3, 30 ]
    in
    let%lwt rows = Db.collect ctx (rows table) () in
    Alcotest.(check (list (pair int int))) "rows" [ 1, 10; 2, 20; 3, 30 ] rows;
    let%lwt missing =
      Db.find_opt
        ctx
        (Caqti.Templater.direct
           Caqti.Templater.T.(unit -->? int)
           (Format.asprintf "SELECT val FROM %s WHERE id = 4" table)
         |> Request.create ~needs:Roles.read)
        ()
    in
    Lwt.return (Alcotest.(check (option int)) "find_opt" None missing)
  ;;

  (* A row type built with Caqti_encoders, through the database: encoding,
     decoding, and a rejecting encoder failing the statement. *)
  let test_custom_row_type () =
    with_table "custom_row_type"
    @@ fun table ->
    let ctx = root_ctx () in
    let entry =
      let open Caqti_encoders in
      let encode (id, value) : (_ Data.t, _) result =
        if value < 0 then Error "negative" else Ok Data.[ id; value ]
      in
      let decode (id, (value, ())) = Ok (id, value) in
      custom ~encode ~decode Schema.[ T.int; T.int ]
    in
    let insert =
      direct
        T.(entry -->. unit)
        (Format.asprintf "INSERT INTO %s (id, val) VALUES (?, ?)" table)
      |> Request.create ~needs:Need.(Roles.read & Roles.write)
    in
    let select =
      direct
        T.(unit -->* entry)
        (Format.asprintf "SELECT id, val FROM %s ORDER BY id" table)
      |> Request.create ~needs:Roles.read
    in
    let%lwt () = Db.exec ctx insert (1, 10) in
    let%lwt () = Db.exec ctx insert (2, 20) in
    let%lwt rows = Db.collect ctx select () in
    Alcotest.(check (list (pair int int))) "rows" [ 1, 10; 2, 20 ] rows;
    (* Caqti 3.1 lets the encoder's [Row_type.Reject] escape instead of
       returning [Encode_rejected]: Request_utils.encode_param only guards the
       partial application of the product encoder. *)
    let%lwt rejected =
      Lwt.catch
        (fun () -> Db.exec ctx insert (3, -1) |> Lwt.map (fun () -> false))
        (function
          | Error.Failed _ | Caqti.Template.Row_type.Reject _ -> Lwt.return_true
          | exn -> Lwt.reraise exn)
    in
    Alcotest.(check bool) "encode error fails the statement" true rejected;
    check_count table 2
  ;;

  (* {1 Tables} *)

  let list_tables () =
    Db.collect
      (root_ctx ())
      (Dialect.request
         Caqti.Template.Request.Direct
         T.(unit -->* string)
         Dialect.list_tables
       |> Request.create ~needs:Roles.read)
      ()
  ;;

  let table_ddl sql =
    Dialect.request Caqti.Template.Request.Direct T.(unit -->. unit) sql
    |> Request.create ~needs:Roles.schema
  ;;

  let test_list_truncate_drop () =
    with_table "tables"
    @@ fun table ->
    let%lwt () = Db.exec (root_ctx ()) (insert table) (1, 1) in
    let%lwt tables = list_tables () in
    Alcotest.(check bool)
      (table ^ " is listed")
      true
      (CCList.mem ~eq:CCString.equal table tables);
    Alcotest.(check bool)
      "listed by name"
      true
      (CCList.equal CCString.equal tables (CCList.sort CCString.compare tables));
    let%lwt () =
      Db.exec (root_ctx ()) (table_ddl (fun kind -> Dialect.truncate kind ~table)) ()
    in
    let%lwt () = check_count table 0 in
    let%lwt () =
      Db.exec (root_ctx ()) (table_ddl (fun kind -> Dialect.drop kind ~table)) ()
    in
    let%lwt tables = list_tables () in
    Alcotest.(check bool)
      (table ^ " is gone")
      false
      (CCList.mem ~eq:CCString.equal table tables);
    (* IF EXISTS *)
    Db.exec (root_ctx ()) (table_ddl (fun kind -> Dialect.drop kind ~table)) ()
  ;;

  (* {1 Foreign key checks} *)

  let fk_parent = "veins_t_fk_parent"
  let fk_child = "veins_t_fk_child"

  let create_fk_tables () =
    let%lwt () =
      Db.exec
        (root_ctx ())
        (table_ddl (fun (_ : Dialect.kind) ->
           Format.asprintf "CREATE TABLE %s (id INTEGER PRIMARY KEY)" fk_parent))
        ()
    in
    Db.exec
      (root_ctx ())
      (table_ddl (fun kind ->
         Format.asprintf
           "CREATE TABLE %s (id INTEGER PRIMARY KEY, parent_id INTEGER NOT NULL, FOREIGN \
            KEY (parent_id) REFERENCES %s (id))%s"
           fk_child
           fk_parent
           (match kind with
            | Dialect.Mariadb -> " ENGINE=InnoDB"
            | Dialect.Postgresql -> "")))
      ()
  ;;

  let drop_fk_tables () =
    let drop table =
      Db.exec (root_ctx ()) (table_ddl (fun kind -> Dialect.drop kind ~table)) ()
    in
    let%lwt () = drop fk_child in
    drop fk_parent
  ;;

  let insert_child =
    direct
      T.(t2 int int -->. unit)
      (Format.asprintf "INSERT INTO %s (id, parent_id) VALUES (?, ?)" fk_child)
  ;;

  let test_without_fk_checks () =
    let%lwt () = drop_fk_tables () in
    let%lwt () = create_fk_tables () in
    Lwt.finalize
      (fun () ->
         Db.connection_ctx ~role:owner root (fun ctx ->
           Db.query
             ~needs:Need.(Roles.read & Roles.write)
             ctx
             (fun ((module C : Caqti_lwt.CONNECTION) as connection) ->
                let switches = Dialect.kind C.dialect = Dialect.Mariadb in
                (* an orphan row is refused: the checks are on *)
                let checks_on name id =
                  if switches
                  then (
                    match%lwt C.exec insert_child (id, 999) with
                    | Ok () -> Alcotest.failf "%s: the orphan row was accepted" name
                    | Error (_ : Caqti.Error.t) -> Lwt.return_unit)
                  else Lwt.return_unit
                in
                let%lwt () = checks_on "before" 1 in
                (* f succeeds *)
                let%lwt result =
                  Connection.without_fk_checks connection (fun () ->
                    if switches
                    then Lwt_result.map (fun () -> 42) (C.exec insert_child (2, 999))
                    else Lwt_result.return 42)
                in
                (match result with
                 | Ok n -> Alcotest.(check int) "f's result" 42 n
                 | Error error ->
                   Alcotest.failf "without_fk_checks: %a" Caqti.Error.pp error);
                let%lwt () = checks_on "after Ok" 3 in
                (* f fails: its error is kept *)
                let%lwt result =
                  Connection.without_fk_checks connection (fun () ->
                    C.exec (direct T.(unit -->. unit) "DELETE FROM veins_t_missing") ())
                in
                (match result with
                 | Error error ->
                   Alcotest.(check bool)
                     (Format.asprintf "f's error: %a" Caqti.Error.pp error)
                     true
                     (CCString.mem ~sub:"veins_t_missing" (Caqti.Error.show error))
                 | Ok () -> Alcotest.fail "expected f's error");
                let%lwt () = checks_on "after Error" 4 in
                (* f raises: re-raised *)
                let%lwt () =
                  ignore_exit (fun () ->
                    let%lwt (_ : (unit, Caqti.Error.t) result) =
                      Connection.without_fk_checks connection (fun () -> Lwt.fail Exit)
                    in
                    Alcotest.fail "expected Exit")
                in
                let%lwt () = checks_on "after an exception" 5 in
                Lwt_result.return ())))
      drop_fk_tables
  ;;

  (* {1 Contexts} *)

  let test_held_connection_is_kept () =
    let connection_id = int_query D.connection_id_sql in
    let check ctx =
      let%lwt a = Db.find ctx connection_id () in
      let%lwt b = Db.find ctx connection_id () in
      Lwt.return (Alcotest.(check int) "same connection" a b)
    in
    let%lwt () = Db.connection_ctx ~role:owner root check in
    Db.transaction_ctx ~role:owner root check
  ;;

  let test_held_connection_serialises () =
    let parallel ctx =
      let%lwt results = Lwt.all (CCList.init 10 (fun (_ : int) -> Db.find ctx ping ())) in
      Lwt.return
        (Alcotest.(check (list int)) "all answered" (CCList.replicate 10 1) results)
    in
    let%lwt () = Db.connection_ctx ~role:owner root parallel in
    Db.transaction_ctx ~role:owner root parallel
  ;;

  let test_session_is_utc () =
    let offset = int_query D.utc_offset_sql in
    let%lwt label_offset = Db.find (root_ctx ()) offset () in
    let%lwt held_offset =
      Db.connection_ctx ~role:owner root (fun ctx -> Db.find ctx offset ())
    in
    Alcotest.(check int) "label ctx session in UTC" 0 label_offset;
    Lwt.return (Alcotest.(check int) "held connection in UTC" 0 held_offset)
  ;;

  (* {1 Transactions} *)

  let test_commit_and_rollback () =
    with_table "txn"
    @@ fun table ->
    let%lwt () =
      Db.transaction_ctx ~role:owner root (fun ctx -> Db.exec ctx (insert table) (1, 1))
    in
    let%lwt () =
      ignore_exit (fun () ->
        Db.transaction_ctx ~role:owner root (fun ctx ->
          let%lwt () = Db.exec ctx (insert table) (2, 2) in
          Lwt.fail Exit))
    in
    check_count table 1
  ;;

  let test_nested_transaction_joins () =
    with_table "nested"
    @@ fun table ->
    (* the outer transaction fails after the inner one returned *)
    let%lwt () =
      ignore_exit (fun () ->
        Db.transaction_ctx ~role:owner root (fun ctx ->
          let%lwt () = Db.exec ctx (insert table) (1, 1) in
          let%lwt () =
            Db.with_transaction ctx (fun inner -> Db.exec inner (insert table) (2, 2))
          in
          let%lwt () =
            Db.transaction
              ~needs:Roles.write
              ctx
              (fun (module C : Caqti_lwt.CONNECTION) ->
                 C.exec (Request.caqti (insert table)) (3, 3))
          in
          Lwt.fail Exit))
    in
    let%lwt () = check_count table 0 in
    (* the inner one fails *)
    let%lwt () =
      ignore_exit (fun () ->
        Db.transaction_ctx ~role:owner root (fun ctx ->
          let%lwt () = Db.exec ctx (insert table) (4, 4) in
          Db.with_transaction ctx (fun inner ->
            let%lwt () = Db.exec inner (insert table) (5, 5) in
            Lwt.fail Exit)))
    in
    let%lwt () = check_count table 0 in
    (* on a held connection it starts a transaction and commits *)
    let%lwt () =
      Db.connection_ctx ~role:owner root (fun ctx ->
        Db.with_transaction ctx (fun inner -> Db.exec inner (insert table) (6, 6)))
    in
    check_count table 1
  ;;

  let test_after_commit () =
    with_table "hooks"
    @@ fun table ->
    let ran = ref [] in
    let%lwt () =
      Db.transaction_ctx ~role:owner root (fun ctx ->
        Ctx.after_commit ctx (fun () -> ran := 1 :: !ran);
        Ctx.after_commit ctx (fun () -> failwith "hook failure");
        Ctx.after_commit ctx (fun () -> ran := 3 :: !ran);
        let%lwt () = Db.exec ctx (insert table) (1, 1) in
        Alcotest.(check (list int)) "not before the commit" [] !ran;
        Lwt.return_unit)
    in
    Alcotest.(check (list int))
      "in registration order, despite a failing one"
      [ 3; 1 ]
      !ran;
    let%lwt () = check_count table 1 in
    let dropped = ref true in
    let%lwt () =
      ignore_exit (fun () ->
        Db.transaction_ctx ~role:owner root (fun ctx ->
          Ctx.after_commit ctx (fun () -> dropped := false);
          Lwt.fail Exit))
    in
    Alcotest.(check bool) "dropped on rollback" true !dropped;
    let immediate = ref false in
    Ctx.after_commit (root_ctx ()) (fun () -> immediate := true);
    Lwt.return (Alcotest.(check bool) "immediate outside a transaction" true !immediate)
  ;;

  (* A second instance with a single connection, so every statement reuses the
     connection the rollback ran on. *)
  module Single = Pools.Make (struct
      let database = database
      let database_pool_size = 1
      let expected_databases = 1

      module Driver = Db.Config.Driver
    end)

  (* caqti-driver-mariadb 3.1 turns autocommit off for a transaction and back
     on when committing, but not when rolling back: the connection went back to
     the pool in a transaction that was never committed. *)
  let test_rollback_restores_autocommit () =
    Single.Pool.initialize ();
    with_table "autocommit"
    @@ fun table ->
    let%lwt () =
      ignore_exit (fun () ->
        Single.transaction_ctx ~role:owner root (fun ctx ->
          let%lwt () = Single.exec ctx (insert table) (1, 1) in
          Lwt.fail Exit))
    in
    let%lwt () =
      ignore_exit (fun () ->
        Single.transaction
          ~needs:Need.none
          (Single.label_ctx ~role:owner root)
          (fun (_ : Caqti_lwt.connection) -> Lwt.fail Exit))
    in
    (* a statement returning an Error inside a raw-connection transaction *)
    let%lwt () =
      Lwt.catch
        (fun () ->
           Single.query
             ~needs:Need.none
             (Single.label_ctx ~role:owner root)
             (fun ((module C : Caqti_lwt.CONNECTION) as connection) ->
                Single.connection_transaction connection (fun () ->
                  C.exec (Request.caqti (insert "veins_t_missing")) (1, 1))))
        (function
          | Error.Failed _ -> Lwt.return_unit
          | exn -> Lwt.reraise exn)
    in
    let%lwt () = Single.exec (Single.label_ctx ~role:owner root) (insert table) (2, 2) in
    (* another connection sees the row only if it was committed *)
    let%lwt n = Db.find (root_ctx ()) (count table) () in
    (* close the connection before asserting: a transaction left open on it
       would block dropping the table *)
    let%lwt pool = Single.Pool.fetch root in
    Single.Pool.clear ();
    let rec wait attempts =
      if Caqti_lwt_unix.Pool.size pool = 0 || attempts = 0
      then Lwt.return_unit
      else (
        let%lwt () = Lwt_unix.sleep 0.05 in
        wait (attempts - 1))
    in
    let%lwt () = wait 100 in
    Lwt.return (Alcotest.(check int) "the write after the rollback was committed" 1 n)
  ;;

  let wait_closed pool =
    let rec wait attempts =
      if Caqti_lwt_unix.Pool.size pool = 0 || attempts = 0
      then Lwt.return_unit
      else (
        let%lwt () = Lwt_unix.sleep 0.05 in
        wait (attempts - 1))
    in
    wait 100
  ;;

  (* caqti-driver-mariadb 3.1's own populate returns after a failing row
     without rolling back: the rows before it stayed in a transaction left
     open on the pooled connection, with autocommit off. *)
  let test_failed_populate_leaves_nothing () =
    Single.Pool.initialize ();
    with_table "populate"
    @@ fun table ->
    let ctx = Single.label_ctx ~role:owner root in
    let%lwt () =
      expect_exn
        "duplicate row"
        (fun () ->
           Single.populate
             ~needs:Roles.write
             ctx
             table
             [ "id"; "val" ]
             T.(t2 int int)
             [ 1, 1; 2, 2; 1, 3 ])
        (function
          | Error.Failed _ -> ()
          | exn -> Alcotest.failf "expected Failed, got %s" (Printexc.to_string exn))
    in
    let%lwt () = Single.exec ctx (insert table) (4, 4) in
    (* another connection sees only what was committed *)
    let%lwt rows = Db.collect (root_ctx ()) (rows table) () in
    let%lwt pool = Single.Pool.fetch root in
    Single.Pool.clear ();
    let%lwt () = wait_closed pool in
    Lwt.return
      (Alcotest.(check (list (pair int int)))
         "no row of the failed populate, the later write committed"
         [ 4, 4 ]
         rows)
  ;;

  (* Code that gets a connection from veins may use all of its interface:
     the driver's own rollback, with_transaction and populate are fixed. *)
  let test_connection_interface_is_fixed () =
    Single.Pool.initialize ();
    with_table "raw"
    @@ fun table ->
    let ctx = Single.label_ctx ~role:owner root in
    let insert = Request.caqti (insert table) in
    let failing f =
      Lwt.catch
        (fun () -> Single.query ~needs:Need.none ctx f)
        (function
          | Error.Failed _ -> Lwt.return_unit
          | exn -> Lwt.reraise exn)
    in
    let duplicate = Caqti_lwt.Stream.of_list [ 1, 1; 1, 2 ] in
    let ( let* ) = Lwt_result.bind in
    (* start / rollback *)
    let%lwt () =
      Single.query ~needs:Need.none ctx (fun (module C : Caqti_lwt.CONNECTION) ->
        let* () = C.start () in
        let* () = C.exec insert (10, 10) in
        C.rollback ())
    in
    (* with_transaction returning an error *)
    let%lwt () =
      failing (fun (module C : Caqti_lwt.CONNECTION) ->
        C.with_transaction (fun () ->
          let* () = C.exec insert (11, 11) in
          C.exec insert (11, 12)))
    in
    (* populate failing on a row *)
    let%lwt () =
      failing (fun (module C : Caqti_lwt.CONNECTION) ->
        C.populate ~table ~columns:[ "id"; "val" ] T.(t2 int int) duplicate
        |> Lwt.map Caqti.Error.uncongested)
    in
    (* populate inside a transaction that is rolled back afterwards *)
    let%lwt () =
      Single.query ~needs:Need.none ctx (fun (module C : Caqti_lwt.CONNECTION) ->
        let* () = C.start () in
        let* () =
          C.populate
            ~table
            ~columns:[ "id"; "val" ]
            T.(t2 int int)
            (Caqti_lwt.Stream.of_list [ 12, 12 ])
          |> Lwt.map Caqti.Error.uncongested
        in
        let* () = C.exec insert (13, 13) in
        C.rollback ())
    in
    let%lwt () = Single.exec ctx (Request.create ~needs:Roles.write insert) (20, 20) in
    let%lwt rows = Db.collect (root_ctx ()) (rows table) () in
    let%lwt pool = Single.Pool.fetch root in
    Single.Pool.clear ();
    let%lwt () = wait_closed pool in
    Lwt.return
      (Alcotest.(check (list (pair int int)))
         "only the write after them, committed"
         [ 20, 20 ]
         rows)
  ;;

  (* In a transaction the rows belong to it, and so does what follows:
     caqti-driver-mariadb 3.1's populate committed the transaction it ran in. *)
  let test_populate_joins_transaction () =
    with_table "populate_txn"
    @@ fun table ->
    let%lwt () =
      ignore_exit (fun () ->
        Db.transaction_ctx ~role:owner root (fun ctx ->
          let%lwt () = Db.exec ctx (insert table) (1, 1) in
          let%lwt () =
            Db.populate
              ~needs:Roles.write
              ctx
              table
              [ "id"; "val" ]
              T.(t2 int int)
              [ 2, 2; 3, 3 ]
          in
          let%lwt () = Db.exec ctx (insert table) (4, 4) in
          Lwt.fail Exit))
    in
    let%lwt () = check_count table 0 in
    let%lwt () =
      Db.transaction_ctx ~role:owner root (fun ctx ->
        Db.populate ~needs:Roles.write ctx table [ "id"; "val" ] T.(t2 int int) [ 5, 5 ])
    in
    check_count table 1
  ;;

  (* {1 Errors} *)

  let test_query_error_keeps_pool () =
    let%lwt pool = Db.Pool.fetch root in
    let%lwt () =
      expect_exn
        "missing table"
        (fun () ->
           Db.find
             (root_ctx ())
             (int_query "SELECT 1 FROM veins_table_that_does_not_exist")
             ())
        (function
          | Error.Failed { Error.label; _ } ->
            Alcotest.(check string) "label" "root" (Label.value label)
          | exn -> Alcotest.failf "expected Failed, got %s" (Printexc.to_string exn))
    in
    let%lwt pool_after = Db.Pool.fetch root in
    let%lwt (_ : int) = Db.find (root_ctx ()) ping () in
    Lwt.return (Alcotest.(check bool) "pool kept" true (pool == pool_after))
  ;;

  let test_unique_violation_cause () =
    with_table "unique"
    @@ fun table ->
    let%lwt () = Db.exec (root_ctx ()) (insert table) (1, 1) in
    expect_exn
      "duplicate key"
      (fun () -> Db.exec (root_ctx ()) (insert table) (1, 2))
      (fun exn ->
         Alcotest.(check bool)
           "Unique_violation"
           true
           (Error.cause_of_exn exn = Some `Unique_violation))
  ;;

  (* {1 Pool lifecycle} *)

  let roles_label = Label.create "veins_roles"

  let roles_database =
    let login_url login role =
      role_url role |> CCOption.map (fun url -> login, Url.create url)
    in
    Database.create
      ~logins:
        (CCList.filter_map
           CCFun.id
           [ login_url Roles.reader_login "READER"
           ; login_url Roles.writer_login "WRITER"
           ; login_url Roles.migrator_login "MIGRATOR"
           ])
      roles_label
      (Url.create url)
  ;;

  let setup () =
    Db.Pool.initialize ();
    Db.Pool.add roles_database
  ;;

  let extra name = Database.create (Label.create name) (Url.create url)

  let test_clear_drains_pools () =
    let database = extra "veins_extra_clear" in
    let label = Database.label database in
    Db.Pool.add database;
    let%lwt (_ : int) =
      Db.connection_ctx ~role:owner label (fun ctx -> Db.find ctx ping ())
    in
    let%lwt pool = Db.Pool.fetch label in
    Db.Pool.clear ();
    setup ();
    let rec wait attempts =
      if Caqti_lwt_unix.Pool.size pool = 0 || attempts = 0
      then Lwt.return_unit
      else (
        let%lwt () = Lwt_unix.sleep 0.05 in
        wait (attempts - 1))
    in
    let%lwt () = wait 100 in
    Alcotest.(check int) "old pool drained" 0 (Caqti_lwt_unix.Pool.size pool);
    let%lwt (_ : int) = Db.find (root_ctx ()) ping () in
    expect_exn
      "cleared label"
      (fun () -> Db.find (Db.label_ctx ~role:owner label) ping ())
      (function
        | Error.Exn (Error.Database_not_registered _) -> ()
        | exn ->
          Alcotest.failf
            "expected Database_not_registered, got %s"
            (Printexc.to_string exn))
  ;;

  let test_drop_with_open_connection () =
    let database = extra "veins_extra_drop" in
    let label = Database.label database in
    Db.Pool.add database;
    let%lwt () =
      Db.connection_ctx ~role:owner label (fun ctx ->
        let%lwt (_ : int) = Db.find ctx ping () in
        (* returns right away, the held connection stays usable *)
        Db.Pool.drop label;
        let%lwt one = Db.find ctx ping () in
        Lwt.return (Alcotest.(check int) "held connection still works" 1 one))
    in
    expect_exn
      "dropped label"
      (fun () -> Db.find (Db.label_ctx ~role:owner label) ping ())
      (function
        | Error.Exn (Error.Database_not_registered _) -> ()
        | exn ->
          Alcotest.failf
            "expected Database_not_registered, got %s"
            (Printexc.to_string exn))
  ;;

  (* The proxy cuts every connection, like a database restart: queries fail
     with a connection error, and the pool recovers once it is back. *)
  let test_outage_and_recovery () =
    let%lwt proxy, proxied =
      Net.Proxy.start ~default_port:D.default_port (Uri.of_string url)
    in
    let label = Label.create "veins_outage" in
    Db.Pool.add (Database.create label (Url.create (Uri.to_string proxied)));
    let ctx = Db.label_ctx ~role:owner label in
    Lwt.finalize
      (fun () ->
         let%lwt (_ : int) = Db.find ctx ping () in
         let%lwt () = Net.Proxy.set_down proxy true in
         let%lwt () =
           expect_exn
             "outage"
             (fun () -> Db.find ctx ping ())
             (function
               | Error.Failed { Error.error; _ } ->
                 Alcotest.(check bool)
                   (Format.asprintf "a connection error: %a" Caqti.Error.pp error)
                   true
                   (Db.Config.Driver.is_connection_error error)
               | exn -> Alcotest.failf "expected Failed, got %s" (Printexc.to_string exn))
         in
         let%lwt () = Net.Proxy.set_down proxy false in
         let rec retry attempts =
           try%lwt Db.find ctx ping () with
           | (Error.Failed _ | Error.Exn _) when attempts > 0 ->
             let%lwt () = Lwt_unix.sleep 0.2 in
             retry (attempts - 1)
         in
         let%lwt one = retry 10 in
         Lwt.return (Alcotest.(check int) "recovered" 1 one))
      (fun () ->
         Db.Pool.drop label;
         Net.Proxy.stop proxy)
  ;;

  (* A server that accepts and never answers. caqti-driver-postgresql connects
     blocking, so without a connect timeout this froze the whole process. *)
  let test_unresponsive_server_fails () =
    let%lwt server = Net.Unresponsive.start () in
    let scheme = Uri.scheme (Uri.of_string url) |> CCOption.value ~default:"" in
    let label = Label.create "veins_unresponsive" in
    Lwt.finalize
      (fun () ->
         Db.Pool.add
           (Database.create label (Url.create (Net.Unresponsive.url server ~scheme)));
         expect_exn
           "unresponsive server"
           (fun () -> Db.find (Db.label_ctx ~role:owner label) ping ())
           (fun (_ : exn) -> ()))
      (fun () ->
         Db.Pool.drop label;
         Net.Unresponsive.stop server)
  ;;

  let test_ping () =
    let%lwt answered = Db.Pool.ping root in
    Alcotest.(check bool) "the database answers" true (Result.is_ok answered);
    let%lwt unknown = Db.Pool.ping (Label.create "veins_unknown") in
    Lwt.return
      (match unknown with
       | Error (Error.Database_not_registered _) -> ()
       | Error error -> Alcotest.failf "unknown label: %s" (Error.show error)
       | Ok () -> Alcotest.fail "unknown label: expected an error")
  ;;

  let test_unregistered_url () =
    let labels () = Db.Pool.find_all () |> CCList.map Database.label in
    let before = labels () in
    let answers name tested =
      match tested with
      | Ok () -> ()
      | Error error -> Alcotest.failf "%s answers: %s" name (Error.show error)
    in
    let%lwt tested = Connection.test (Url.create url) in
    answers "the URL" tested;
    let%lwt tested = Db.Pool.test (extra "veins_extra_unregistered") in
    answers "the database" tested;
    Lwt.return
      (Alcotest.(check (list string))
         "nothing registered"
         (CCList.map Label.value before)
         (CCList.map Label.value (labels ())))
  ;;

  (* Every URL of the database is tested, and a success ends the connection
     issue of the registered database. *)
  let test_database_test () =
    let status label =
      Db.Pool.find label |> CCOption.map Database.status |> CCOption.map Status.show
    in
    let%lwt tested = Db.Pool.test roles_database in
    Alcotest.(check bool) "owner and logins answer" true (Result.is_ok tested);
    Alcotest.(check (option string))
      "an active database stays active"
      (Some "active")
      (status roles_label);
    let database =
      extra "veins_extra_test" |> Database.with_status Status.ConnectionIssue
    in
    let label = Database.label database in
    Db.Pool.add database;
    Lwt.finalize
      (fun () ->
         let%lwt tested = Db.Pool.test database in
         Alcotest.(check bool) "the database answers" true (Result.is_ok tested);
         Lwt.return
           (Alcotest.(check (option string))
              "the connection issue is over"
              (Some "active")
              (status label)))
      (fun () -> Lwt.return (Db.Pool.drop label))
  ;;

  (* Pools with a statement timeout and a single connection that statements
     wait for half a second at most. *)
  module Tuned =
    Pools.Make_with_options
      (struct
        let database = database
        let database_pool_size = 1
        let expected_databases = 1

        module Driver = Db.Config.Driver
      end)
      (struct
        let options =
          Pool_options.
            { default with
              statement_timeout = Some 7.
            ; acquire_timeout = Some 0.5
            ; max_idle_age = Some 0.2
            ; max_use_count = Some 50
            }
        ;;
      end)

  let test_options () =
    Tuned.Pool.initialize ();
    let ctx = Tuned.label_ctx ~role:owner root in
    let%lwt timeout = Tuned.find ctx (int_query D.statement_timeout_sql) () in
    Alcotest.(check int) "statement timeout of the session" 7 timeout;
    let%lwt () =
      Tuned.connection_ctx ~role:owner root (fun held ->
        let%lwt (_ : int) = Tuned.find held ping () in
        expect_exn
          "exhausted pool"
          (fun () -> Tuned.find ctx ping ())
          (function
            | Error.Exn (Error.Connection_failed _) -> ()
            | exn ->
              Alcotest.failf "expected Connection_failed, got %s" (Printexc.to_string exn)))
    in
    (* the abandoned request doesn't keep the connection *)
    let%lwt one = Tuned.find ctx ping () in
    Alcotest.(check int) "pool usable again" 1 one;
    (* idle connections are closed *)
    let%lwt pool = Tuned.Pool.fetch root in
    let%lwt () = wait_closed pool in
    Alcotest.(check int) "idle connection closed" 0 (Caqti_lwt_unix.Pool.size pool);
    let%lwt one = Tuned.find ctx ping () in
    Tuned.Pool.clear ();
    Lwt.return (Alcotest.(check int) "reconnects" 1 one)
  ;;

  (* [on_failure] hears of a statement failing inside a transaction once, not
     again when the error leaves the transaction and its connection. *)
  let failures : Pool_options.failure list ref = ref []

  module Reporting =
    Pools.Make_with_options
      (Db.Config)
      (struct
        let options =
          Pool_options.
            { default with
              on_failure =
                Some
                  (fun failure ->
                    failures := failure :: !failures;
                    Lwt.return_unit)
            }
        ;;
      end)

  let test_on_failure () =
    Reporting.Pool.initialize ();
    let missing = int_query "SELECT n FROM veins_test_no_such_table" in
    let%lwt () =
      expect_exn
        "missing table"
        (fun () ->
           Reporting.transaction_ctx ~role:owner root (fun ctx ->
             Reporting.find ctx missing ()))
        (function
          | Error.Failed _ -> ()
          | exn -> Alcotest.failf "expected Failed, got %s" (Printexc.to_string exn))
    in
    let reported = !failures in
    failures := [];
    Reporting.Pool.clear ();
    Alcotest.(check int) "reported once" 1 (CCList.length reported);
    CCList.iter
      (fun { Pool_options.request; role; _ } ->
         Alcotest.(check (option string)) "role" (Some (Role.name owner)) role;
         Alcotest.(check bool)
           "request"
           true
           (CCOption.exists (CCString.mem ~sub:"veins_test_no_such_table") request))
      reported;
    Lwt.return_unit
  ;;

  (* {1 Roles} *)

  let as_role role = Db.label_ctx ~role roles_label

  (* Each role runs what its type grants, on its login's URL or, without
     one, on the owner's. Misuse doesn't compile, see test/typing. *)
  let test_roles_run_their_statements () =
    with_table ~ctx:(fun () -> as_role Roles.migrator) "roles"
    @@ fun table ->
    let%lwt () = Db.exec (as_role Roles.writer) (insert table) (1, 1) in
    let%lwt () =
      Db.transaction_ctx ~role:Roles.writer roles_label (fun ctx ->
        Db.with_transaction ctx (fun inner -> Db.exec inner (insert table) (2, 2)))
    in
    let%lwt n = Db.find (as_role Roles.reader) (count table) () in
    Lwt.return (Alcotest.(check int) "reader reads what the writer wrote" 2 n)
  ;;

  (* Needs one database user per role (the *_READER_URL etc. variables). *)
  let test_roles_run_as_their_user () =
    if not distinct_role_users then Alcotest.skip ();
    let%lwt reader =
      Db.find (as_role Roles.reader) (string_query D.current_user_sql) ()
    in
    let%lwt writer =
      Db.find (as_role Roles.writer) (string_query D.current_user_sql) ()
    in
    Alcotest.(check bool)
      ("reader is " ^ reader)
      true
      (CCString.mem ~sub:"veins_reader" reader);
    Lwt.return
      (Alcotest.(check bool)
         ("writer is " ^ writer)
         true
         (CCString.mem ~sub:"veins_writer" writer))
  ;;

  (* A role claiming more than its login is granted: the types allow the
     statement, the database refuses it. Needs the per-role users. *)
  let test_overstated_role_is_refused () =
    if not distinct_role_users then Alcotest.skip ();
    let overstated : [ `Read | `Write ] Role.t =
      Role.v ~login:Roles.reader_login "overstated"
    in
    with_table ~ctx:(fun () -> as_role Roles.migrator) "overstated"
    @@ fun table ->
    let%lwt () =
      expect_exn
        "overstated role"
        (fun () -> Db.exec (as_role overstated) (insert table) (1, 1))
        (permission_denied "overstated role" ~login:"reader" ~needs:[ "read"; "write" ])
    in
    let%lwt n = Db.find (as_role Roles.reader) (count table) () in
    Lwt.return (Alcotest.(check int) "nothing written" 0 n)
  ;;

  (* {1 Migrations} *)

  module Runner = Migration.Make (Db)

  (* The suite may share its database with an application: only ever touch
     the migration state of the suite's own namespaces. *)
  let forget_test_migrations () =
    (* creates the state table if there is none *)
    let%lwt (_ : (unit, Error.t) result) = Runner.run_all ~migrations:[] root () in
    Db.exec
      (root_ctx ())
      (direct
         T.(unit -->. unit)
         (Format.asprintf
            "DELETE FROM %s WHERE namespace LIKE 'veins_test_%%'"
            (Migration.state_table ()))
       |> Request.create ~needs:Roles.write)
      ()
  ;;

  let test_migration () =
    let ns =
      Migration.Namespace.create (Format.asprintf "veins_test_mig_%d" (Random.int 100000))
    in
    let%lwt () = forget_test_migrations () in
    let%lwt () = Db.exec (root_ctx ()) (drop_table "veins_t_mig") () in
    let mig =
      Migration.(
        create ns ~written_at:(ptime_of_string "2024-01-01T00:00:00Z")
        |> add_step
             (Step.create
                ~label:"create table"
                ~down:(Sql.any "DROP TABLE IF EXISTS veins_t_mig")
                (Sql.any "CREATE TABLE veins_t_mig (id INTEGER PRIMARY KEY)"))
        |> add_step
             (Step.create
                ~label:"insert row without FK checks"
                ~check_fk:false
                ~down:(Sql.any "DELETE FROM veins_t_mig WHERE id = 42")
                (Sql.any "INSERT INTO veins_t_mig (id) VALUES (42)")))
    in
    Alcotest.(check (list string))
      "ids derived from the positions"
      (CCList.map
         (fun index ->
            Migration.Id.(value (derive ~namespace:(Migration.Namespace.value ns) ~index)))
         [ 0; 1 ])
      (CCList.map Migration.Id.value (Migration.step_ids mig));
    Migration.register ~for_databases:(Migration.Database root) mig;
    let ok name = function
      | Ok () -> ()
      | Error e -> Alcotest.failf "%s: %s" name (Error.show e)
    in
    let applied () =
      let%lwt statuses = Runner.status root () in
      match
        CCList.find_opt (fun (n, _, _) -> Migration.Namespace.equal n ns) statuses
      with
      | Some (_, applied, _) -> Lwt.return applied
      | None -> Alcotest.failf "namespace %s not in status" (Migration.Namespace.show ns)
    in
    let%lwt () = Runner.run_all root () |> Lwt.map (ok "run_all") in
    let%lwt n = applied () in
    Alcotest.(check int) "applied" 2 n;
    let%lwt () = Runner.run_all root () |> Lwt.map (ok "idempotent") in
    let%lwt drifts = Runner.check root () in
    Alcotest.(check int) "no drift" 0 (CCList.length drifts);
    let%lwt () = Runner.down root mig |> Lwt.map (ok "down") in
    let%lwt n = applied () in
    Alcotest.(check int) "reverted" 0 n;
    let%lwt () = forget_test_migrations () in
    Db.exec (root_ctx ()) (drop_table "veins_t_mig") ()
  ;;

  (* Importing another engine's state: the first step ran already (the table
     exists), [mark_applied] records it, [up] runs only the rest. *)
  let test_migration_import () =
    let namespace = Format.asprintf "veins_test_import_%d" (Random.int 100000) in
    let id index = Migration.Id.derive ~namespace ~index in
    let mig =
      Migration.(
        create
          (Namespace.create namespace)
          ~written_at:(Migration.ptime_of_string "2024-01-01T00:00:00Z")
        |> add_step
             (Step.create
                ~id:(id 0)
                ~label:"create table"
                (Sql.any "CREATE TABLE veins_t_import (id INTEGER PRIMARY KEY)"))
        |> add_step
             (Step.create
                ~id:(id 1)
                ~label:"insert row"
                (Sql.any "INSERT INTO veins_t_import (id) VALUES (1)")))
    in
    let%lwt () = Db.exec (root_ctx ()) (drop_table "veins_t_import") () in
    let%lwt () =
      Db.exec
        (root_ctx ())
        (ddl "CREATE TABLE veins_t_import (id INTEGER PRIMARY KEY)")
        ()
    in
    let%lwt () = Runner.mark_applied root mig ~steps:1 in
    let%lwt () = Runner.mark_applied root mig ~steps:1 in
    let%lwt pending = Runner.pending ~migrations:[ mig ] root () in
    Alcotest.(check (list (pair string int)))
      "one step pending"
      [ namespace, 1 ]
      (CCList.map (fun (ns, n) -> Migration.Namespace.value ns, n) pending);
    let%lwt () =
      Runner.up root mig
      |> Lwt.map (function
        | Ok () -> ()
        | Error e -> Alcotest.failf "up: %s" (Error.show e))
    in
    let%lwt rows = Db.find (root_ctx ()) (count "veins_t_import") () in
    Alcotest.(check int) "only the second step ran" 1 rows;
    let%lwt pending = Runner.pending ~migrations:[ mig ] root () in
    Alcotest.(check int) "nothing pending" 0 (CCList.length pending);
    let%lwt () = forget_test_migrations () in
    Db.exec (root_ctx ()) (drop_table "veins_t_import") ()
  ;;

  (* Instances of an application starting together: each step runs once. *)
  let test_migration_runs_once () =
    let namespace = Format.asprintf "veins_test_lock_%d" (Random.int 100000) in
    let id index = Migration.Id.derive ~namespace ~index in
    let mig =
      Migration.(
        create
          (Namespace.create namespace)
          ~written_at:(Migration.ptime_of_string "2024-01-01T00:00:00Z")
        |> add_step
             (Step.create
                ~id:(id 0)
                ~label:"create table"
                (Sql.any "CREATE TABLE veins_t_lock (id INTEGER PRIMARY KEY)"))
        |> add_step
             (Step.create
                ~id:(id 1)
                ~label:"insert row"
                (Sql.any "INSERT INTO veins_t_lock (id) VALUES (1)")))
    in
    let%lwt () = forget_test_migrations () in
    let%lwt () = Db.exec (root_ctx ()) (drop_table "veins_t_lock") () in
    let%lwt results =
      Lwt.all
        (CCList.init 4 (fun (_ : int) -> Runner.run_all ~migrations:[ mig ] root ()))
    in
    CCList.iter
      (function
        | Ok () -> ()
        | Error e -> Alcotest.failf "concurrent run_all: %s" (Error.show e))
      results;
    let%lwt rows = Db.find (root_ctx ()) (count "veins_t_lock") () in
    Alcotest.(check int) "the steps ran once" 1 rows;
    let%lwt () = forget_test_migrations () in
    Db.exec (root_ctx ()) (drop_table "veins_t_lock") ()
  ;;

  let connection_kind () =
    Db.connection_ctx ~role:owner root (fun ctx ->
      Db.query ~needs:Need.none ctx (fun (module C : Caqti_lwt.CONNECTION) ->
        Lwt.return_ok (Dialect.kind C.dialect)))
  ;;

  (* A run with a step that has no SQL for the connection's dialect applies
     nothing, not even the migrations before it. *)
  let test_migration_dialects () =
    let%lwt kind = connection_kind () in
    let other : Dialect.kind =
      match kind with
      | Dialect.Mariadb -> Dialect.Postgresql
      | Dialect.Postgresql -> Dialect.Mariadb
    in
    let migration name step =
      let namespace = Format.asprintf "veins_test_%s_%d" name (Random.int 100000) in
      Migration.(
        create
          (Namespace.create namespace)
          ~written_at:(Migration.ptime_of_string "2024-01-01T00:00:00Z")
        |> add_step step)
    in
    let supported =
      migration
        "dialect_ok"
        (Migration.Step.create
           ~label:"create table"
           (Migration.Sql.only
              kind
              "CREATE TABLE veins_t_dialect (id INTEGER PRIMARY KEY)"))
    in
    let unsupported =
      migration
        "dialect_other"
        (Migration.Step.create
           ~label:"other dialect only"
           (Migration.Sql.only other "INSERT INTO veins_t_dialect (id) VALUES (1)"))
    in
    let placeholder =
      migration
        "dialect_todo"
        (Migration.Step.create
           ~label:"left a TODO"
           (Migration.Sql.v
              ~mariadb:"TODO: forward SQL"
              ~postgresql:"TODO: forward SQL"
              ()))
    in
    let migrations = [ supported; unsupported; placeholder ] in
    let%lwt () = forget_test_migrations () in
    let%lwt () = Db.exec (root_ctx ()) (drop_table "veins_t_dialect") () in
    let fails name result =
      match result with
      | Error (Error.Migration_failed (_ : string)) -> ()
      | Error e -> Alcotest.failf "%s: unexpected error %s" name (Error.show e)
      | Ok () -> Alcotest.failf "%s: succeeded" name
    in
    let%lwt () = Runner.verify ~migrations root () |> Lwt.map (fails "verify") in
    let%lwt () = Runner.run_all ~migrations root () |> Lwt.map (fails "run_all") in
    let%lwt () = Runner.up root unsupported |> Lwt.map (fails "up") in
    let%lwt pending = Runner.pending ~migrations root () in
    let%lwt () = Runner.up root placeholder |> Lwt.map (fails "up placeholder") in
    Alcotest.(check int) "nothing applied" 3 (CCList.length pending);
    let%lwt drifts = Runner.check ~migrations root () in
    let unsupported_steps =
      CCList.filter_map
        (function
          | Migration.Unsupported { steps; dialect; _ } when dialect = kind -> Some steps
          | Migration.Unsupported _ | Migration.Pending _ | Migration.Orphaned _ -> None)
        drifts
    in
    Alcotest.(check (list (list string)))
      "check names the step"
      [ [ "other dialect only" ]; [ "left a TODO" ] ]
      unsupported_steps;
    let%lwt () =
      Runner.run_all ~migrations:[ supported ] root ()
      |> Lwt.map (function
        | Ok () -> ()
        | Error e -> Alcotest.failf "supported alone: %s" (Error.show e))
    in
    let%lwt () =
      Runner.verify ~migrations:[ supported ] root ()
      |> Lwt.map (function
        | Ok () -> ()
        | Error e -> Alcotest.failf "verify supported: %s" (Error.show e))
    in
    let unwritten_down =
      migration
        "dialect_down"
        (Migration.Step.create
           ~label:"down left a TODO"
           ~down:
             (Migration.Sql.v
                ~mariadb:"TODO: reverse SQL"
                ~postgresql:"TODO: reverse SQL"
                ())
           (Migration.Sql.only kind "CREATE TABLE veins_t_dialect_down (id INTEGER)"))
    in
    let%lwt () = Db.exec (root_ctx ()) (drop_table "veins_t_dialect_down") () in
    Lwt.finalize
      (fun () ->
         let%lwt () =
           Runner.up root unwritten_down
           |> Lwt.map (function
             | Ok () -> ()
             | Error e -> Alcotest.failf "up with a TODO down: %s" (Error.show e))
         in
         let%lwt () =
           Runner.down root unwritten_down |> Lwt.map (fails "down placeholder")
         in
         let%lwt pending = Runner.pending ~migrations:[ unwritten_down ] root () in
         Alcotest.(check int) "down reverted nothing" 0 (CCList.length pending);
         (* the table [up] created is still there *)
         Db.exec (root_ctx ()) (ddl "INSERT INTO veins_t_dialect_down (id) VALUES (1)") ())
      (fun () ->
         let%lwt () = forget_test_migrations () in
         let%lwt () = Db.exec (root_ctx ()) (drop_table "veins_t_dialect_down") () in
         Db.exec (root_ctx ()) (drop_table "veins_t_dialect") ())
  ;;

  (* The counter bridge, on a table of its own. Uses the deprecated API on
     purpose. *)
  module Counter_tests = struct
    [@@@alert "-deprecated"]

    module Counters = Migration.Counter_state.Make (Db)

    let table = "veins_test_counters"

    let set_counter namespace version dirty =
      Db.exec
        (root_ctx ())
        (ddl
           (Format.asprintf
              "INSERT INTO %s (namespace, version, dirty) VALUES ('%s', %d, %s)"
              table
              namespace
              version
              (if dirty then "TRUE" else "FALSE")))
        ()
    ;;

    let counter namespace =
      Db.find_opt
        (root_ctx ())
        (direct
           T.(string -->? t2 int bool)
           (Format.asprintf "SELECT version, dirty FROM %s WHERE namespace = ?" table)
         |> Request.create ~needs:Roles.read)
        namespace
    ;;

    let test () =
      let namespace = Format.asprintf "veins_test_counter_%d" (Random.int 100000) in
      let step label =
        Migration.(
          Step.create
            ~label
            (Sql.any "CREATE TABLE IF NOT EXISTS veins_t_counter (id INTEGER)"))
      in
      let mig =
        Migration.(
          create
            (Namespace.create namespace)
            ~written_at:(Migration.ptime_of_string "2024-01-01T00:00:00Z")
          |> add_step (step "one")
          |> add_step (step "two"))
      in
      let%lwt () = forget_test_migrations () in
      let%lwt () = Db.exec (root_ctx ()) (drop_table table) () in
      let pending () =
        let%lwt pending = Runner.pending ~migrations:[ mig ] root () in
        Lwt.return (CCList.fold_left (fun n (_, k) -> n + k) 0 pending)
      in
      let imported name =
        Lwt.map (function
          | Ok state -> state
          | Error (`Dirty (_ : string list)) -> Alcotest.failf "%s: dirty" name)
      in
      (* no table: nothing to import, [record] creates it *)
      let%lwt state = Counters.import ~table root [ mig ] |> imported "no table" in
      let%lwt n = pending () in
      Alcotest.(check int) "no table, nothing marked" 2 n;
      let%lwt () =
        Counters.record ~table root state mig.Migration.namespace ~applied:0 ~failed:true
      in
      let%lwt row = counter namespace in
      Alcotest.(check (option (pair int bool))) "table created" (Some (0, true)) row;
      (* dirty: refused, nothing marked *)
      let%lwt () =
        match%lwt Counters.import ~table root [ mig ] with
        | Error (`Dirty namespaces) ->
          Lwt.return (Alcotest.(check (list string)) "dirty" [ namespace ] namespaces)
        | Ok (_ : Migration.Counter_state.state) -> Alcotest.fail "dirty imported"
      in
      (* one step counted: marked, the other pending *)
      let%lwt () =
        Db.exec (root_ctx ()) (ddl (Format.asprintf "DELETE FROM %s" table)) ()
      in
      let%lwt () = set_counter namespace 1 false in
      let%lwt state = Counters.import ~table root [ mig ] |> imported "counted" in
      let%lwt n = pending () in
      Alcotest.(check int) "one step marked" 1 n;
      let%lwt () =
        Runner.up root mig
        |> Lwt.map (function
          | Ok () -> ()
          | Error e -> Alcotest.failf "up: %s" (Error.show e))
      in
      let%lwt () =
        Counters.record ~table root state mig.Migration.namespace ~applied:2 ~failed:false
      in
      let%lwt row = counter namespace in
      Alcotest.(check (option (pair int bool))) "counter updated" (Some (2, false)) row;
      let%lwt () = forget_test_migrations () in
      let%lwt () = Db.exec (root_ctx ()) (drop_table "veins_t_counter") () in
      Db.exec (root_ctx ()) (drop_table table) ()
    ;;
  end

  (* {1 Without roles} *)

  module Plain_db = Veins.Plain.Make (Db)

  (* The statements above as plain Caqti requests. *)
  let plain = Request.caqti

  let test_plain_statements () =
    with_table "plain"
    @@ fun table ->
    let ctx = Plain_db.label_ctx root in
    let%lwt () = Plain_db.exec ctx (plain (insert table)) (1, 10) in
    let%lwt () =
      Plain_db.populate ctx table [ "id"; "val" ] T.(t2 int int) [ 2, 20; 3, 30 ]
    in
    let%lwt found = Plain_db.collect ctx (plain (rows table)) () in
    Alcotest.(check (list (pair int int))) "rows" [ 1, 10; 2, 20; 3, 30 ] found;
    let%lwt n = Plain_db.find ctx (plain (count table)) () in
    Alcotest.(check int) "count" 3 n;
    let%lwt n =
      Plain_db.query ctx (fun connection ->
        let module Connection = (val connection : Caqti_lwt.CONNECTION) in
        Connection.find (plain (count table)) ())
    in
    Alcotest.(check int) "count on the connection" 3 n;
    let%lwt ids =
      Plain_db.connection_ctx root (fun ctx ->
        let%lwt first = Plain_db.find ctx (plain (int_query D.connection_id_sql)) () in
        let%lwt second = Plain_db.find ctx (plain (int_query D.connection_id_sql)) () in
        Lwt.return (first, second))
    in
    Alcotest.(check bool) "one held connection" true (fst ids = snd ids);
    Lwt.return_unit
  ;;

  let test_plain_transactions () =
    with_table "plain_txn"
    @@ fun table ->
    let insert = plain (insert table) in
    let committed = ref [] in
    let note name ctx =
      Veins.Plain.Ctx.after_commit ctx (fun () -> committed := name :: !committed)
    in
    let%lwt () =
      Plain_db.transaction_ctx root (fun ctx ->
        note "outer" ctx;
        let%lwt () = Plain_db.exec ctx insert (1, 1) in
        Plain_db.with_transaction ctx (fun inner ->
          note "inner" inner;
          Alcotest.(check bool)
            "in a transaction"
            true
            (Veins.Plain.Ctx.is_transaction inner);
          Plain_db.exec inner insert (2, 2)))
    in
    let%lwt () =
      ignore_exit (fun () ->
        Plain_db.transaction_ctx root (fun ctx ->
          note "rolled back" ctx;
          let%lwt () = Plain_db.exec ctx insert (3, 3) in
          Lwt.fail Exit))
    in
    Alcotest.(check (list string))
      "hooks of the commit only"
      [ "inner"; "outer" ]
      !committed;
    check_count table 2
  ;;

  (* Statements with needs run on a single-user context, in its
     transaction. *)
  let test_plain_with_roles () =
    with_table "plain_roles"
    @@ fun table ->
    let%lwt () =
      Plain_db.transaction_ctx root (fun ctx ->
        let%lwt () = Db.exec (Veins.Plain.Ctx.with_roles ctx) (insert table) (1, 1) in
        let%lwt n = Plain_db.find ctx (plain (count table)) () in
        Lwt.return (Alcotest.(check int) "seen in the transaction" 1 n))
    in
    let%lwt () =
      ignore_exit (fun () ->
        Plain_db.transaction_ctx root (fun ctx ->
          let%lwt () = Db.exec (Veins.Plain.Ctx.with_roles ctx) (insert table) (2, 2) in
          Lwt.fail Exit))
    in
    check_count table 1
  ;;

  let cases =
    let open Alcotest_lwt in
    let case name speed f = test_case name speed (fun (_ : Lwt_switch.t) () -> f ()) in
    [ ( "statements"
      , [ case "roundtrip" `Quick test_roundtrip
        ; case "failed populate leaves nothing" `Quick test_failed_populate_leaves_nothing
        ; case "populate joins its transaction" `Quick test_populate_joins_transaction
        ; case
            "the connection's own interface is fixed"
            `Quick
            test_connection_interface_is_fixed
        ] )
    ; ( "contexts"
      , [ case "held connection is kept" `Quick test_held_connection_is_kept
        ; case "held connection serialises" `Quick test_held_connection_serialises
        ; case "session is UTC" `Quick test_session_is_utc
        ] )
    ; "row types", [ case "custom row type" `Quick test_custom_row_type ]
    ; "tables", [ case "list, truncate and drop tables" `Quick test_list_truncate_drop ]
    ; ( "transactions"
      , [ case "commit and rollback" `Quick test_commit_and_rollback
        ; case "nested transaction joins" `Quick test_nested_transaction_joins
        ; case "after_commit hooks" `Quick test_after_commit
        ; case "rollback restores autocommit" `Quick test_rollback_restores_autocommit
        ; case "without_fk_checks" `Quick test_without_fk_checks
        ] )
    ; ( "errors"
      , [ case "query error keeps the pool" `Quick test_query_error_keeps_pool
        ; case "unique violation cause" `Quick test_unique_violation_cause
        ] )
    ; ( "pools"
      , [ case "clear drains pools" `Quick test_clear_drains_pools
        ; case "drop with an open connection" `Quick test_drop_with_open_connection
        ; case "outage and recovery" `Slow test_outage_and_recovery
        ; case "unresponsive server fails" `Slow test_unresponsive_server_fails
        ; case "ping" `Quick test_ping
        ; case "test an unregistered URL" `Quick test_unregistered_url
        ; case "test a database" `Quick test_database_test
        ; case "options" `Quick test_options
        ; case "on_failure" `Quick test_on_failure
        ] )
    ; ( "roles"
      , [ case "roles run their statements" `Quick test_roles_run_their_statements
        ; case "roles run as their user" `Quick test_roles_run_as_their_user
        ; case "overstated role is refused" `Quick test_overstated_role_is_refused
        ] )
    ; ( "without roles"
      , [ case "statements" `Quick test_plain_statements
        ; case "transactions and hooks" `Quick test_plain_transactions
        ; case "statements with needs join" `Quick test_plain_with_roles
        ] )
    ; ( "migrations"
      , [ case "run_all, check, down" `Quick test_migration
        ; case "import another engine's state" `Quick test_migration_import
        ; case "concurrent runners apply once" `Quick test_migration_runs_once
        ; case "steps without SQL for the dialect" `Quick test_migration_dialects
        ; case "import a counter table" `Quick Counter_tests.test
        ] )
    ]
  ;;

  let run name =
    Random.self_init ();
    if Option.is_some (env_opt "VEINS_TEST_DEBUG")
    then (
      Logs.set_reporter (Logs_fmt.reporter ());
      Logs.set_level (Some Logs.Debug));
    setup ();
    Lwt_main.run (Alcotest_lwt.run name cases)
  ;;
end

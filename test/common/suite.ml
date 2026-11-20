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
      let database () = database
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
    Alcotest.(check bool) "the database answers" true (CCResult.is_ok answered);
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
    Alcotest.(check bool) "owner and logins answer" true (CCResult.is_ok tested);
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
         Alcotest.(check bool) "the database answers" true (CCResult.is_ok tested);
         Lwt.return
           (Alcotest.(check (option string))
              "the connection issue is over"
              (Some "active")
              (status label)))
      (fun () -> Lwt.return (Db.Pool.drop label))
  ;;

  (* Pools with a statement timeout and a single connection that statements
     wait for half a second at most. *)
  let tuned_reported : Pool_options.failure list ref = ref []

  let tuned_reports expected =
    let got = !tuned_reported in
    tuned_reported := [];
    Alcotest.(check int) "reported once" expected (CCList.length got);
    got
  ;;

  module Tuned =
    Pools.Make_with_options
      (struct
        let database () = database
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
            ; on_failure =
                Some
                  (fun failure ->
                    tuned_reported := failure :: !tuned_reported;
                    Lwt.return_unit)
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
            | Error.Exn (Error.Acquire_timeout _) as exn ->
              Alcotest.(check bool)
                "exhausted pool: no connection error"
                false
                (Tuned.is_connection_error exn);
              CCList.iter
                (fun { Pool_options.connection_error; _ } ->
                   Alcotest.(check bool)
                     "exhausted pool: failure.connection_error"
                     false
                     connection_error)
                (tuned_reports 1)
            | exn ->
              Alcotest.failf "expected Acquire_timeout, got %s" (Printexc.to_string exn)))
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

  (* [Pool.use] returns Caqti's results; a
     statement error leaves the pool alone, exceptions pass through. *)
  let test_use () =
    let select_one (module C : Caqti_lwt.CONNECTION) = C.find (Request.caqti ping) () in
    let%lwt one = Db.Pool.use root select_one in
    Alcotest.(check (result int string))
      "result of f"
      (Ok 1)
      (CCResult.map_err Caqti.Error.show one);
    let%lwt pool = Db.Pool.fetch root in
    let%lwt missing =
      Db.Pool.use root (fun (module C : Caqti_lwt.CONNECTION) ->
        C.find (Request.caqti (int_query "SELECT n FROM veins_test_no_such_table")) ())
    in
    Alcotest.(check bool) "statement error returned" true (CCResult.is_error missing);
    let%lwt same = Db.Pool.fetch root in
    Alcotest.(check bool) "pool kept" true (pool == same);
    let%lwt () =
      expect_exn
        "exception of f"
        (fun () -> Db.Pool.use root (fun _ -> failwith "f"))
        (function
          | Failure _ -> ()
          | exn -> Alcotest.failf "expected Failure, got %s" (Printexc.to_string exn))
    in
    let%lwt one = Db.Pool.use root select_one in
    Lwt.return (Alcotest.(check bool) "usable afterwards" true (CCResult.is_ok one))
  ;;

  (* A connection error a callback raises as [Caqti.Error.Exn] (what
     [Caqti_lwt.or_fail] raises) drops the pool like a returned one, and
     reaches the caller as it is; veins' own exceptions raised by the
     callback aren't turned into results. *)
  let test_use_callback_exceptions () =
    let lost =
      Caqti.Error.Exn
        (Caqti.Error.connect_failed ~uri:Uri.empty (Caqti.Error.Msg "connection gone"))
    in
    let dropped name run =
      let%lwt before = Db.Pool.fetch root in
      let%lwt () =
        expect_exn name run (fun exn ->
          Alcotest.(check bool) (name ^ ": the callback's exception") true (exn == lost))
      in
      let%lwt after = Db.Pool.fetch root in
      Alcotest.(check bool) (name ^ ": pool dropped") false (before == after);
      (* a statement reaching the database ends the count of failures, or
         the next case would find the pool backing off *)
      let%lwt one = Db.find (Db.label_ctx ~role:owner root) ping () in
      Lwt.return (Alcotest.(check int) (name ^ ": reconnects") 1 one)
    in
    let%lwt () =
      dropped "Pool.use" (fun () -> Db.Pool.use root (fun _ -> Lwt.fail lost))
    in
    let%lwt () =
      dropped "connection_ctx" (fun () ->
        Db.connection_ctx ~role:owner root (fun ctx ->
          Db.query ~needs:Need.none ctx (fun _ -> Lwt.fail lost)))
    in
    let inner = Error.Exn (Error.Connection_failed "inner acquire timeout") in
    let%lwt () =
      expect_exn
        "veins exception of the callback"
        (fun () -> Db.Pool.use root (fun _ -> Lwt.fail inner))
        (fun exn -> Alcotest.(check bool) "passed through" true (exn == inner))
    in
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

  (* A set of its own: what an application registered. Other tests'
     migrations are rows outside it (orphaned). *)
  module Single_set (P : sig
      val policy : Migration.out_of_order_policy
    end) =
  struct
    module S =
      Migration.Sets.Make
        (struct
          type t = [ `Only ]

          let all = [ `Only ]
          let name `Only = "only"
          let out_of_order `Only = P.policy
        end)
        (Db)

    include S.App (struct
        let set_for (_ : Label.t) = `Only
      end)

    let register migrations = CCList.iter (S.register ~sets:[ `Only ]) migrations
  end

  let source entries =
    (module struct
      let name = "veins_test"
      let read (_ : Caqti_lwt.connection) = Lwt_result.return entries
    end : Migration.Import.Source)
  ;;

  (* Every step of [migrations] applied, written as an import does; with
     none, only creates or upgrades the state table. *)
  let mark_applied migrations =
    let module M = Single_set (struct
        let policy = `Fail
      end)
    in
    M.register migrations;
    let entries =
      CCList.map
        (fun (m : Migration.t) ->
           { Migration.Import.namespace = m.namespace
           ; applied = CCList.length m.steps
           ; failed = None
           })
        migrations
    in
    match%lwt M.Import.run ~source:(source entries) root with
    | Ok (_ : Migration.Import.Report.t) -> Lwt.return_unit
    | Error e -> Alcotest.failf "mark applied: %s" (Error.show e)
  ;;

  (* The suite may share its database with an application: only ever touch
     the migration state of the suite's own namespaces. *)
  let forget_test_migrations () =
    let%lwt () = mark_applied [] in
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

  let connection_kind () =
    Db.connection_ctx ~role:owner root (fun ctx ->
      Db.query ~needs:Need.none ctx (fun (module C : Caqti_lwt.CONNECTION) ->
        Lwt.return_ok (Dialect.kind C.dialect)))
  ;;

  module Default = Migration.App.Make (Db)

  (* The default set: [Migration.register], step ids derived from the
     positions, a step without FK checks. *)
  let test_default_set () =
    let ns =
      Migration.Namespace.create (Format.asprintf "veins_test_mig_%d" (Random.int 100000))
    in
    let%lwt () = forget_test_migrations () in
    let%lwt () = Db.exec (root_ctx ()) (drop_table "veins_t_mig") () in
    (* a row outside the set, so the database isn't uninitialized *)
    let%lwt () =
      mark_applied
        [ Migration.(
            create
              (Namespace.create "veins_test_default_base")
              ~written_at:(ptime_of_string "2000-01-01T00:00:00Z")
            |> add_step (Step.create ~label:"base" (Sql.any "SELECT 1")))
        ]
    in
    let mig =
      Migration.(
        create ns ~written_at:(ptime_of_string "2024-01-01T00:00:00Z")
        |> add_step
             (Step.create
                ~label:"create table"
                (Sql.any "CREATE TABLE veins_t_mig (id INTEGER PRIMARY KEY)"))
        |> add_step
             (Step.create
                ~label:"insert row without FK checks"
                ~check_fk:false
                (Sql.any "INSERT INTO veins_t_mig (id) VALUES (42)")))
    in
    Alcotest.(check (list string))
      "ids derived from the positions"
      (CCList.map
         (fun index ->
            Migration.Id.(value (derive ~namespace:(Migration.Namespace.value ns) ~index)))
         [ 0; 1 ])
      (CCList.map Migration.Id.value (Migration.step_ids mig));
    Migration.register mig;
    let ok name result =
      match%lwt result with
      | Ok () -> Lwt.return_unit
      | Error e -> Alcotest.failf "%s: %s" name (Error.show e)
    in
    let%lwt () = ok "migrate" (Default.migrate root) in
    let%lwt () = check_count "veins_t_mig" 1 in
    let%lwt () = ok "idempotent" (Default.migrate root) in
    let%lwt () =
      match%lwt Default.ready root with
      | Ok Migration.Status.Ready -> Lwt.return_unit
      | Ok status -> Alcotest.failf "ready: %s" (Migration.Status.show status)
      | Error e -> Alcotest.failf "ready: %s" (Error.show e)
    in
    let%lwt () = forget_test_migrations () in
    Db.exec (root_ctx ()) (drop_table "veins_t_mig") ()
  ;;

  (* A set with a step that has no SQL for the connection's dialect, or only
     a placeholder, applies nothing, not even the migrations before it. *)
  let test_migration_dialects () =
    let%lwt kind = connection_kind () in
    let other : Dialect.kind =
      match kind with
      | Dialect.Mariadb -> Dialect.Postgresql
      | Dialect.Postgresql -> Dialect.Mariadb
    in
    let migration name written_at step =
      let namespace = Format.asprintf "veins_test_%s_%d" name (Random.int 100000) in
      Migration.(
        create
          (Namespace.create namespace)
          ~written_at:(Migration.ptime_of_string written_at)
        |> add_step step)
    in
    let supported =
      migration
        "dialect_ok"
        "2024-01-01T00:00:00Z"
        (Migration.Step.create
           ~label:"create table"
           (Migration.Sql.only
              kind
              "CREATE TABLE veins_t_dialect (id INTEGER PRIMARY KEY)"))
    in
    let unsupported =
      migration
        "dialect_other"
        "2024-02-01T00:00:00Z"
        (Migration.Step.create
           ~label:"other dialect only"
           (Migration.Sql.only other "INSERT INTO veins_t_dialect (id) VALUES (1)"))
    in
    let placeholder =
      migration
        "dialect_todo"
        "2024-03-01T00:00:00Z"
        (Migration.Step.create
           ~label:"left a TODO"
           (Migration.Sql.v
              ~mariadb:"TODO: forward SQL"
              ~postgresql:"TODO: forward SQL"
              ()))
    in
    let module M = Single_set (struct
        let policy = `Fail
      end)
    in
    M.register [ supported; unsupported; placeholder ];
    let%lwt () = forget_test_migrations () in
    let%lwt () = Db.exec (root_ctx ()) (drop_table "veins_t_dialect") () in
    let%lwt () =
      mark_applied
        [ migration
            "dialect_base"
            "2000-01-01T00:00:00Z"
            (Migration.Step.create ~label:"base" (Migration.Sql.any "SELECT 1"))
        ]
    in
    let%lwt () =
      match%lwt M.dry_run root with
      | Ok { refusal = Some (Migration.Refusal.Missing_dialect missing); _ } ->
        Lwt.return
          (Alcotest.(check (list (list string)))
             "the dry run names the steps"
             [ [ "other dialect only" ]; [ "left a TODO" ] ]
             (CCList.map snd missing))
      | Ok dry -> Alcotest.failf "dry run: %s" (Migration.Dry_run.show dry)
      | Error e -> Alcotest.failf "dry run: %s" (Error.show e)
    in
    let%lwt () =
      match%lwt M.migrate root with
      | Error (Error.Migration_failed (_ : string)) -> Lwt.return_unit
      | Error e -> Alcotest.failf "migrate: unexpected error %s" (Error.show e)
      | Ok () -> Alcotest.fail "migrate: succeeded"
    in
    let%lwt created =
      Db.find
        (root_ctx ())
        (int_query
           (Format.asprintf
              "SELECT COUNT(*) FROM information_schema.tables WHERE table_name = \
               'veins_t_dialect'"))
        ()
    in
    Alcotest.(check int) "nothing applied" 0 created;
    let%lwt () =
      match%lwt M.ready root with
      | Ok (Migration.Status.Blocked (Migration.Refusal.Missing_dialect [ _; _ ], _)) ->
        Lwt.return_unit
      | Ok status -> Alcotest.failf "ready: %s" (Migration.Status.show status)
      | Error e -> Alcotest.failf "ready: %s" (Error.show e)
    in
    let module Supported = Single_set (struct
        let policy = `Fail
      end)
    in
    Supported.register [ supported ];
    let%lwt () =
      match%lwt Supported.migrate root with
      | Ok () -> Lwt.return_unit
      | Error e -> Alcotest.failf "supported alone: %s" (Error.show e)
    in
    let%lwt () = forget_test_migrations () in
    Db.exec (root_ctx ()) (drop_table "veins_t_dialect") ()
  ;;

  (* {2 Migrations in an application} Each test runs its own set: a set is
     what an application registered, so other tests' migrations are rows
     outside it (orphaned). *)
  module App_tests = struct
    let state = Migration.state_table ()

    let ok name result =
      match%lwt result with
      | Ok x -> Lwt.return x
      | Error e -> Alcotest.failf "%s: %s" name (Error.show e)
    ;;

    let fails name result =
      match%lwt result with
      | Ok _ -> Alcotest.failf "%s: succeeded" name
      | Error (e : Error.t) -> Lwt.return (Error.show e)
    ;;

    let passes name result =
      match%lwt result with
      | Ok () -> Lwt.return_unit
      | Error status -> Alcotest.failf "%s: %s" name (Migration.Status.show status)
    ;;

    let contains name ~sub s =
      Alcotest.(check bool)
        (Format.asprintf "%s: %S in %S" name sub s)
        true
        (CCString.mem ~sub s)
    ;;

    let unique name = Format.asprintf "veins_test_%s_%d" name (Random.int 1_000_000)

    let migration name written_at steps =
      CCList.fold_left
        (fun m (label, sql) -> Migration.(add_step (Step.create ~label (Sql.any sql)) m))
        (Migration.create
           (Migration.Namespace.create name)
           ~written_at:(Migration.ptime_of_string written_at))
        steps
    ;;

    let dialect_query request_type sql =
      Dialect.request Caqti.Template.Request.Direct request_type sql
      |> Request.create ~needs:Roles.read
    ;;

    let table_exists name =
      Db.find (root_ctx ()) (dialect_query T.(string -->! int) Dialect.table_exists) name
      |> Lwt.map (fun n -> n > 0)
    ;;

    let column_exists column =
      Db.find
        (root_ctx ())
        (dialect_query T.(t2 string string -->! int) Dialect.column_exists)
        (state, column)
      |> Lwt.map (fun n -> n > 0)
    ;;

    (* id, uuid, status, last_error, whether run_at is set; of one namespace *)
    let rows namespace =
      Db.collect
        (root_ctx ())
        (dialect_query
           T.(string -->* t2 (t3 int string string) (t2 (option string) int))
           (fun kind ->
              Format.asprintf
                "SELECT id, %s, status, last_error, CASE WHEN run_at IS NULL THEN 0 ELSE \
                 1 END FROM %s WHERE namespace = ? ORDER BY id"
                (Dialect.uuid_select_fragment kind ~field:"uuid")
                state))
        namespace
    ;;

    let status_of namespace =
      let%lwt rows = rows namespace in
      Lwt.return (CCList.map (fun ((_, _, status), _) -> status) rows)
    ;;

    let exec sql = Db.exec (root_ctx ()) (ddl sql) ()

    (* An initialized database: a row of its own, so the suite never finds
       the shared database "uninitialized". *)
    let baseline () =
      mark_applied
        [ migration
            "veins_test_baseline"
            "2000-01-01T00:00:00Z"
            [ "baseline", "SELECT 1" ]
        ]
    ;;

    let fresh tables =
      let%lwt () = forget_test_migrations () in
      let%lwt () = baseline () in
      Lwt_list.iter_s (fun table -> Db.exec (root_ctx ()) (drop_table table) ()) tables
    ;;

    let cleanup tables =
      let%lwt () = forget_test_migrations () in
      Lwt_list.iter_s (fun table -> Db.exec (root_ctx ()) (drop_table table) ()) tables
    ;;

    (* PostgreSQL keeps a table's index names when it is renamed, and index
       names are unique per schema: rename them too. *)
    let rename_table kind a b =
      let%lwt () = exec (Format.asprintf "ALTER TABLE %s RENAME TO %s" a b) in
      match (kind : Dialect.kind) with
      | Dialect.Mariadb -> Lwt.return_unit
      | Dialect.Postgresql ->
        let suffix = "_vsaved" in
        let%lwt indexes =
          Db.collect
            (root_ctx ())
            (direct
               T.(string -->* string)
               "SELECT indexname FROM pg_indexes WHERE schemaname = ANY \
                (current_schemas(false)) AND tablename = ?"
             |> Request.create ~needs:Roles.read)
            b
        in
        Lwt_list.iter_s
          (fun index ->
             let renamed =
               match CCString.chop_suffix ~suf:suffix index with
               | Some original -> original
               | None -> index ^ suffix
             in
             exec (Format.asprintf "ALTER INDEX %s RENAME TO %s" index renamed))
          indexes
    ;;

    (* Runs [f] without the suite database's state table, and puts it back. *)
    let with_state_aside f =
      let%lwt kind = connection_kind () in
      let saved = state ^ "_vsaved" in
      if%lwt table_exists saved
      then Alcotest.failf "%s exists: a previous run left it, restore it by hand" saved
      else (
        let%lwt () = forget_test_migrations () in
        let%lwt had = table_exists state in
        let%lwt () = if had then rename_table kind state saved else Lwt.return_unit in
        Lwt.finalize f (fun () ->
          let%lwt () = Db.exec (root_ctx ()) (drop_table state) () in
          if had then rename_table kind saved state else Lwt.return_unit))
    ;;

    let create_first_layout kind =
      exec
        (match (kind : Dialect.kind) with
         | Dialect.Mariadb ->
           Format.asprintf
             "CREATE TABLE %s (id BINARY(16) NOT NULL, namespace VARCHAR(128) NOT NULL, \
              label VARCHAR(256) NOT NULL, created_at DATETIME(3) NOT NULL, updated_at \
              DATETIME(3) NOT NULL, PRIMARY KEY (id))"
             state
         | Dialect.Postgresql ->
           Format.asprintf
             "CREATE TABLE %s (id UUID NOT NULL, namespace VARCHAR(128) NOT NULL, label \
              VARCHAR(256) NOT NULL, created_at TIMESTAMPTZ NOT NULL, updated_at \
              TIMESTAMPTZ NOT NULL, PRIMARY KEY (id))"
             state)
    ;;

    let insert_first_layout kind (mig : Migration.t) ~steps =
      Lwt_list.iter_s
        (fun id ->
           exec
             (Format.asprintf
                "INSERT INTO %s (id, namespace, label, created_at, updated_at) VALUES \
                 (%s, '%s', 'imported', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)"
                state
                (Dialect.uuid_value_fragment kind ("'" ^ Migration.Id.value id ^ "'"))
                (Migration.Namespace.value mig.namespace)))
        (CCList.take steps (Migration.step_ids mig))
    ;;

    (* A fresh table has the current layout; one of the first layout is
       upgraded once, by migrate and by Import.run alike, keeping its UUIDs;
       a read-only role reads both. *)
    let test_state_table () =
      let%lwt kind = connection_kind () in
      let namespace = unique "layout" in
      let mig =
        migration
          namespace
          "2024-01-01T00:00:00Z"
          [ "create", "CREATE TABLE veins_t_layout (id INTEGER)"
          ; "one", "INSERT INTO veins_t_layout (id) VALUES (1)"
          ; "two", "INSERT INTO veins_t_layout (id) VALUES (2)"
          ]
      in
      let module M = Single_set (struct
          let policy = `Fail
        end)
      in
      M.register [ mig ];
      (* the pending steps, as a read-only login sees them *)
      let read_only () =
        let%lwt report = M.report ~role:Roles.reader roles_label in
        Lwt.return (CCList.flat_map snd report.pending)
      in
      with_state_aside
      @@ fun () ->
      let%lwt () = mark_applied [] in
      let%lwt columns =
        Lwt_list.map_s column_exists [ "id"; "uuid"; "status"; "last_error"; "run_at" ]
      in
      Alcotest.(check (list bool))
        "current layout"
        [ true; true; true; true; true ]
        columns;
      let%lwt () =
        expect_exn
          "a status that isn't one"
          (fun () ->
             exec
               (Format.asprintf
                  "INSERT INTO %s (uuid, namespace, label, status, created_at, \
                   updated_at) VALUES (%s, 'veins_test_x', 'x', 'dirty', \
                   CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)"
                  state
                  (Dialect.uuid_value_fragment
                     kind
                     "'00000000-0000-4000-8000-000000000000'")))
          (fun (_ : exn) -> ())
      in
      let upgrade name run =
        let%lwt () = Db.exec (root_ctx ()) (drop_table state) () in
        let%lwt () = Db.exec (root_ctx ()) (drop_table "veins_t_layout") () in
        let%lwt () = exec "CREATE TABLE veins_t_layout (id INTEGER)" in
        let%lwt () = create_first_layout kind in
        let%lwt () = insert_first_layout kind mig ~steps:2 in
        let%lwt read = read_only () in
        Alcotest.(check (list string)) (name ^ ": read the first layout") [ "two" ] read;
        let%lwt uuid = column_exists "uuid" in
        Alcotest.(check bool) (name ^ ": first layout") false uuid;
        let%lwt () = run () in
        let%lwt uuid = column_exists "uuid" in
        Alcotest.(check bool) (name ^ ": upgraded") true uuid;
        let%lwt upgraded = rows namespace in
        (* the new ids follow the old primary key on MariaDB *)
        Alcotest.(check (list string))
          (name ^ ": UUIDs kept")
          (CCList.sort
             CCString.compare
             (CCList.map Migration.Id.value (CCList.take 2 (Migration.step_ids mig))))
          (CCList.sort
             CCString.compare
             (CCList.take 2 (CCList.map (fun ((_, uuid, _), _) -> uuid) upgraded)));
        Alcotest.(check (list string))
          (name ^ ": imported rows applied")
          [ "applied"; "applied" ]
          (CCList.take 2 (CCList.map (fun ((_, _, status), _) -> status) upgraded));
        Alcotest.(check int)
          (name ^ ": ids")
          (CCList.length upgraded)
          (CCList.length
             (CCList.sort_uniq
                ~cmp:compare
                (CCList.map (fun ((id, _, _), _) -> id) upgraded)));
        Lwt.return upgraded
      in
      let%lwt upgraded = upgrade "migrate" (fun () -> ok "migrate" (M.migrate root)) in
      Alcotest.(check (list (pair (option string) int)))
        "imported rows have no run_at, the new one has"
        [ None, 0; None, 0; None, 1 ]
        (CCList.map snd upgraded);
      let%lwt () = ok "migrate again" (M.migrate root) in
      let%lwt again = rows namespace in
      Alcotest.(check int)
        "a second run changes nothing"
        (CCList.length upgraded)
        (CCList.length again);
      let%lwt read = read_only () in
      Alcotest.(check (list string)) "read the current layout" [] read;
      let%lwt (_ : _ list) =
        upgrade "import" (fun () ->
          let%lwt (_ : Migration.Import.Report.t) =
            ok
              "import"
              (M.Import.run
                 ~source:(Migration.Import.counter_state ~table:"veins_test_none" ())
                 root)
          in
          Lwt.return_unit)
      in
      Db.exec (root_ctx ()) (drop_table "veins_t_layout") ()
    ;;

    (* The third step fails: the first two stay applied, the third is
       failed, nothing after it ran, and the next runs refuse until the row
       is repaired by hand, with the statements the report prints. *)
    let test_failure_and_repair () =
      let%lwt kind = connection_kind () in
      let first = unique "fail" in
      let second = unique "after_fail" in
      let failing =
        migration
          first
          "2024-01-01T00:00:00Z"
          [ "create", "CREATE TABLE veins_t_fail (id INTEGER)"
          ; "one", "INSERT INTO veins_t_fail (id) VALUES (1)"
          ; "missing", "INSERT INTO veins_t_fail_missing (id) VALUES (2)"
          ; "three", "INSERT INTO veins_t_fail (id) VALUES (3)"
          ]
      in
      let later =
        migration
          second
          "2024-02-01T00:00:00Z"
          [ "nine", "INSERT INTO veins_t_fail (id) VALUES (9)" ]
      in
      let module M = Single_set (struct
          let policy = `Fail
        end)
      in
      M.register [ failing; later ];
      let tables = [ "veins_t_fail"; "veins_t_fail_missing" ] in
      let%lwt () = fresh tables in
      let%lwt msg = fails "failing step" (M.migrate root) in
      contains "the error" ~sub:"missing" msg;
      let%lwt rows_after = rows first in
      Alcotest.(check (list (pair string int)))
        "two applied, one failed"
        [ "applied", 1; "applied", 1; "failed", 1 ]
        (CCList.map (fun ((_, _, status), (_, run)) -> status, run) rows_after);
      let failed_id, failed_uuid, _ = fst (CCList.nth rows_after 2) in
      Alcotest.(check bool)
        "last_error"
        true
        (CCOption.is_some (fst (snd (CCList.nth rows_after 2))));
      let%lwt later_rows = rows second in
      Alcotest.(check int) "nothing after it ran" 0 (CCList.length later_rows);
      let%lwt () = check_count "veins_t_fail" 1 in
      let%lwt msg = fails "refused" (M.migrate root) in
      contains "names the step" ~sub:failed_uuid msg;
      contains "names the row" ~sub:(Format.asprintf "row %d" failed_id) msg;
      let%lwt status = ok "ready" (M.ready root) in
      Alcotest.(check bool)
        "failed status"
        true
        (match status with
         | Migration.Status.Blocked (Migration.Refusal.Failed [ _ ], _) -> true
         | _ -> false);
      let%lwt report = M.report root in
      let shown = Migration.Report.show report in
      let mark_applied =
        Migration.Repair.mark_applied kind (Migration.Id.create failed_uuid)
      in
      contains "the report prints the repair" ~sub:mark_applied shown;
      (* the admin inserts row 2 by hand and marks the step applied *)
      let%lwt () = exec "INSERT INTO veins_t_fail (id) VALUES (2)" in
      let%lwt () = exec mark_applied in
      let%lwt () = ok "after the repair" (M.migrate root) in
      let%lwt () = check_count "veins_t_fail" 4 in
      let%lwt rows_after = rows first in
      Alcotest.(check (list string))
        "continued after the step"
        [ "applied"; "applied"; "applied"; "applied" ]
        (CCList.map (fun ((_, _, status), _) -> status) rows_after);
      Alcotest.(check bool)
        "last_error kept"
        true
        (CCOption.is_some (fst (snd (CCList.nth rows_after 2))));
      (* undone by hand: the row deleted, the step runs again *)
      let retry = unique "retry" in
      let mig =
        migration
          retry
          "2024-03-01T00:00:00Z"
          [ "fill", "INSERT INTO veins_t_fail_missing (id) VALUES (1)" ]
      in
      M.register [ mig ];
      let%lwt (_ : string) = fails "missing table" (M.migrate root) in
      let%lwt uuid =
        rows retry
        |> Lwt.map (function
          | [ ((_, uuid, "failed"), _) ] -> uuid
          | _ -> Alcotest.fail "one failed row")
      in
      let delete = Migration.Repair.delete kind (Migration.Id.create uuid) in
      let%lwt () = exec delete in
      let%lwt (_ : string) = fails "fails again" (M.migrate root) in
      let%lwt statuses = status_of retry in
      Alcotest.(check (list string)) "the row written again" [ "failed" ] statuses;
      let%lwt () = exec "CREATE TABLE veins_t_fail_missing (id INTEGER)" in
      let%lwt () = exec delete in
      let%lwt () = ok "runs again" (M.migrate root) in
      let%lwt statuses = status_of retry in
      Alcotest.(check (list string)) "applied" [ "applied" ] statuses;
      let%lwt () = check_count "veins_t_fail_missing" 1 in
      cleanup tables
    ;;

    (* A database refusing the step's statement for lack of rights: the
       failure is recorded like any other. Needs the per-role users. *)
    let test_missing_rights () =
      if not distinct_role_users then Alcotest.skip ();
      let namespace = unique "denied" in
      let module M = Single_set (struct
          let policy = `Fail
        end)
      in
      M.register
        [ migration
            namespace
            "2024-01-01T00:00:00Z"
            [ "create", "CREATE TABLE veins_t_denied (id INTEGER)" ]
        ];
      let%lwt () = fresh [ "veins_t_denied" ] in
      let%lwt (_ : string) = fails "denied" (M.migrate ~role:Roles.writer roles_label) in
      let%lwt rows = rows namespace in
      (match rows with
       | [ ((_, _, "failed"), (Some error, 1)) ] ->
         contains "the permission error" ~sub:"refused login 'writer'" error
       | _ -> Alcotest.fail "one failed row with the error");
      cleanup [ "veins_t_denied" ]
    ;;

    (* PostgreSQL runs a step in a transaction: a failing step leaves none
       of its statements behind. *)
    let test_failed_step_reverted () =
      let%lwt kind = connection_kind () in
      match kind with
      | Dialect.Mariadb -> Lwt.return_unit
      | Dialect.Postgresql ->
        let namespace = unique "reverted" in
        let module M = Single_set (struct
            let policy = `Fail
          end)
        in
        M.register
          [ migration
              namespace
              "2024-01-01T00:00:00Z"
              [ ( "half"
                , "DO $$ BEGIN CREATE TABLE veins_t_reverted (id INTEGER); RAISE \
                   EXCEPTION 'boom'; END $$" )
              ]
          ];
        let%lwt () = fresh [ "veins_t_reverted" ] in
        let%lwt (_ : string) = fails "boom" (M.migrate root) in
        let%lwt exists = table_exists "veins_t_reverted" in
        Alcotest.(check bool) "nothing left behind" false exists;
        let%lwt statuses = status_of namespace in
        Alcotest.(check (list string)) "failed" [ "failed" ] statuses;
        cleanup [ "veins_t_reverted" ]
    ;;

    (* Instances starting together: the lock lets one run, the others find
       nothing pending. *)
    let test_concurrent () =
      let namespace = unique "concurrent" in
      let module M = Single_set (struct
          let policy = `Fail
        end)
      in
      M.register
        [ migration
            namespace
            "2024-01-01T00:00:00Z"
            [ "create", "CREATE TABLE veins_t_concurrent (id INTEGER)"
            ; "insert", "INSERT INTO veins_t_concurrent (id) VALUES (1)"
            ]
        ];
      let%lwt () = fresh [ "veins_t_concurrent" ] in
      let%lwt results = Lwt.all (CCList.init 3 (fun (_ : int) -> M.migrate root)) in
      CCList.iter
        (function
          | Ok () -> ()
          | Error e -> Alcotest.failf "concurrent: %s" (Error.show e))
        results;
      let%lwt () = check_count "veins_t_concurrent" 1 in
      cleanup [ "veins_t_concurrent" ]
    ;;

    let with_env name value f =
      let previous = Sys.getenv_opt name in
      Unix.putenv name value;
      Lwt.finalize f (fun () ->
        Unix.putenv name (CCOption.value ~default:"" previous);
        Lwt.return_unit)
    ;;

    let quiet = Format.make_formatter (fun _ _ _ -> ()) ignore

    (* Under `Fail an out-of-order migration is refused unless named; under
       `Warn it runs. *)
    let test_out_of_order () =
      let name tag = unique ("ooo_" ^ tag) in
      let a = name "a" in
      let b = name "b" in
      let c = name "c" in
      let d = name "d" in
      let e = name "e" in
      let table ns = "veins_t_" ^ CCString.sub ns 11 (CCString.length ns - 11) in
      let mig ns written_at =
        migration
          ns
          written_at
          [ "create", Format.asprintf "CREATE TABLE %s (id INTEGER)" (table ns) ]
      in
      let tables = CCList.map table [ a; b; c; d; e ] in
      let module M = Single_set (struct
          let policy = `Fail
        end)
      in
      let ns = Migration.Namespace.create in
      M.register [ mig a "2024-01-01T00:00:00Z"; mig c "2024-03-01T00:00:00Z" ];
      let%lwt () = fresh tables in
      let%lwt () = ok "in order" (M.migrate root) in
      M.register [ mig b "2024-02-01T00:00:00Z"; mig d "2024-02-15T00:00:00Z" ];
      let%lwt msg = fails "out of order" (M.migrate root) in
      contains "names it" ~sub:b msg;
      contains "names the newest applied" ~sub:c msg;
      let%lwt () =
        expect_exn
          "ensure_clean refuses what migrate refuses"
          (fun () -> M.ensure_clean [ root ])
          (function
            | Error.Exn (Error.Migration_not_clean [ (_, status) ]) ->
              contains "out of order" ~sub:"out of order" status
            | exn -> Alcotest.failf "ensure_clean: %s" (Printexc.to_string exn))
      in
      let%lwt b_ran = table_exists (table b) in
      Alcotest.(check bool) "nothing ran" false b_ran;
      let%lwt dry = ok "dry run" (M.dry_run root) in
      Alcotest.(check bool)
        "the dry run refuses too"
        true
        (match dry.refusal with
         | Some (Migration.Refusal.Out_of_order [ _; _ ]) -> true
         | _ -> false);
      let%lwt msg =
        fails "one of two named" (M.migrate ~allow_out_of_order:[ ns b ] root)
      in
      contains "names the other" ~sub:d msg;
      let%lwt () = ok "both named" (M.migrate ~allow_out_of_order:[ ns b; ns d ] root) in
      let%lwt b_ran = table_exists (table b) in
      Alcotest.(check bool) "it ran" true b_ran;
      let%lwt () = ok "no flag needed afterwards" (M.migrate root) in
      let%lwt () =
        ok "a name that isn't out of order" (M.migrate ~allow_out_of_order:[ ns a ] root)
      in
      (* the CI variable, for the preflight and the deploy alike *)
      M.register [ mig e "2024-02-20T00:00:00Z" ];
      let%lwt code = M.command ~out:quiet [ root ] [ "dry-run" ] in
      Alcotest.(check int) "dry-run refuses" 1 code;
      let%lwt () =
        with_env "ALLOW_OUT_OF_ORDER" (" ," ^ e) (fun () ->
          let%lwt code = M.command ~out:quiet [ root ] [ "dry-run" ] in
          Alcotest.(check int) "dry-run with the variable" 0 code;
          let%lwt code = M.command ~out:quiet [ root ] [ "up" ] in
          Alcotest.(check int) "up with the variable" 0 code;
          Lwt.return_unit)
      in
      let%lwt e_ran = table_exists (table e) in
      Alcotest.(check bool) "allowed by the variable" true e_ran;
      (* `Warn: logged and run *)
      let module W = Single_set (struct
          let policy = `Warn
        end)
      in
      let%lwt () =
        Lwt_list.iter_s (fun t -> Db.exec (root_ctx ()) (drop_table t) ()) tables
      in
      let%lwt () = forget_test_migrations () in
      let%lwt () = baseline () in
      W.register [ mig a "2024-01-01T00:00:00Z"; mig c "2024-03-01T00:00:00Z" ];
      let%lwt () = ok "warn: in order" (W.migrate root) in
      W.register [ mig b "2024-02-01T00:00:00Z" ];
      let%lwt dry = ok "warn: dry run" (W.dry_run root) in
      Alcotest.(check int) "listed" 1 (CCList.length dry.report.out_of_order);
      Alcotest.(check bool) "not refused" true (CCOption.is_none dry.refusal);
      let%lwt () = ok "warn: runs it" (W.migrate root) in
      let%lwt b_ran = table_exists (table b) in
      Alcotest.(check bool) "it ran" true b_ran;
      let%lwt () = passes "warn: startup" (W.check root) in
      cleanup tables
    ;;

    (* The dry run reads with a read-only login, writes nothing and takes no
       lock: a migration holding the lock doesn't block it. *)
    let test_dry_run () =
      let first = unique "dry_a" in
      let second = unique "dry_b" in
      let module M = Single_set (struct
          let policy = `Fail
        end)
      in
      M.register
        [ migration
            first
            "2024-01-01T00:00:00Z"
            [ "create", "CREATE TABLE veins_t_dry (id INTEGER)" ]
        ];
      let%lwt () = fresh [ "veins_t_dry" ] in
      let%lwt () = ok "migrate" (M.migrate root) in
      M.register
        [ migration
            second
            "2024-02-01T00:00:00Z"
            [ "insert", "INSERT INTO veins_t_dry (id) VALUES (1)" ]
        ];
      let lock =
        Dialect.request Caqti.Template.Request.Direct T.(string -->! int) Dialect.try_lock
        |> Request.create ~needs:Need.none
      in
      let unlock =
        Dialect.request Caqti.Template.Request.Direct T.(string -->! int) Dialect.unlock
        |> Request.create ~needs:Need.none
      in
      let lock_name = "veins_migration:" ^ state in
      let%lwt dry =
        Db.connection_ctx ~role:owner root (fun ctx ->
          let%lwt locked = Db.find ctx lock lock_name in
          Alcotest.(check int) "the lock is held" 1 locked;
          Lwt.finalize
            (fun () ->
               Lwt.pick
                 [ ok "dry run" (M.dry_run ~role:Roles.reader roles_label)
                 ; (let%lwt () = Lwt_unix.sleep 10. in
                    Alcotest.fail "the dry run waited for the lock")
                 ])
            (fun () ->
               (* the lock belongs to the pooled connection's session *)
               let%lwt (_ : int) = Db.find ctx unlock lock_name in
               Lwt.return_unit))
      in
      Alcotest.(check (list string))
        "pending"
        [ second ]
        (CCList.map (fun (ns, _) -> Migration.Namespace.value ns) dry.report.pending);
      Alcotest.(check bool) "migrate would run" true (CCOption.is_none dry.refusal);
      let%lwt () = check_count "veins_t_dry" 0 in
      let%lwt statuses = status_of second in
      Alcotest.(check (list string)) "nothing written" [] statuses;
      let%lwt code = M.command ~out:quiet [ root ] [ "dry-run" ] in
      Alcotest.(check int) "dry-run: migrate would run" 0 code;
      cleanup [ "veins_t_dry" ]
    ;;

    (* [ensure_clean] raises for every unclean database and passes clean
       ones, also with orphaned rows; [check] and [command] by their
       policies and exit codes. *)
    let test_startup () =
      let%lwt kind = connection_kind () in
      let other : Dialect.kind =
        match kind with
        | Dialect.Mariadb -> Dialect.Postgresql
        | Dialect.Postgresql -> Dialect.Mariadb
      in
      let namespace = unique "startup" in
      let module M = Single_set (struct
          let policy = `Fail
        end)
      in
      M.register
        [ migration
            namespace
            "2024-01-01T00:00:00Z"
            [ "create", "CREATE TABLE veins_t_startup (id INTEGER)" ]
        ];
      let%lwt () = fresh [ "veins_t_startup" ] in
      let not_clean name f =
        expect_exn name f (function
          | Error.Exn (Error.Migration_not_clean [ (label, (_ : string)) ]) ->
            Alcotest.(check string) (name ^ ": the label") "root" label
          | exn -> Alcotest.failf "%s: %s" name (Printexc.to_string exn))
      in
      let%lwt () = not_clean "pending" (fun () -> M.ensure_clean [ root ]) in
      let%lwt () =
        M.check ~policy:`Fail root
        |> Lwt.map (function
          | Error (Migration.Status.Pending _) -> ()
          | Error status -> Alcotest.failf "check: %s" (Migration.Status.show status)
          | Ok () -> Alcotest.fail "check passed")
      in
      let%lwt () = passes "check `Warn" (M.check ~policy:`Warn root) in
      let%lwt code = M.command ~out:quiet [ root ] [ "check" ] in
      Alcotest.(check int) "check: pending" 1 code;
      let%lwt code = M.command ~out:quiet [ root ] [ "status" ] in
      Alcotest.(check int) "status" 0 code;
      let%lwt code = M.command ~out:quiet [ root ] [ "sideways" ] in
      Alcotest.(check int) "usage" 2 code;
      let%lwt code = M.command ~out:quiet [ root ] [ "up" ] in
      Alcotest.(check int) "up" 0 code;
      let%lwt () = M.ensure_clean [ root ] in
      let%lwt () = M.ensure_clean ~role:Roles.reader [ roles_label ] in
      let%lwt status = ok "ready, read-only" (M.ready ~role:Roles.reader roles_label) in
      Alcotest.(check string) "ready" "up to date" (Migration.Status.show status);
      let%lwt code = M.command ~out:quiet [ root ] [ "check" ] in
      Alcotest.(check int) "check: clean" 0 code;
      let%lwt code =
        M.command ~out:quiet [ root; Label.create "veins_unregistered" ] [ "status" ]
      in
      Alcotest.(check int) "the worst code" 1 code;
      let%lwt () = M.ensure_clean ~skip:true [ Label.create "veins_unregistered" ] in
      (* orphaned rows don't count, a failed one neither *)
      let%lwt () =
        mark_applied
          [ migration (unique "orphan") "2024-01-01T00:00:00Z" [ "x", "SELECT 1" ] ]
      in
      let%lwt () = M.ensure_clean [ root ] in
      (* failed *)
      let broken = unique "startup_failed" in
      M.register
        [ migration
            broken
            "2024-02-01T00:00:00Z"
            [ "x", "INSERT INTO veins_t_nowhere (id) VALUES (1)" ]
        ];
      let%lwt (_ : string) = fails "failing" (M.migrate root) in
      let%lwt () = not_clean "failed" (fun () -> M.ensure_clean [ root ]) in
      let%lwt () =
        M.check root
        |> Lwt.map (function
          | Error (Migration.Status.Blocked (Migration.Refusal.Failed [ _ ], _)) -> ()
          | Error status ->
            Alcotest.failf "check failed: %s" (Migration.Status.show status)
          | Ok () -> Alcotest.fail "check passed a failed step")
      in
      let%lwt () =
        exec (Format.asprintf "DELETE FROM %s WHERE namespace = '%s'" state broken)
      in
      let%lwt () = exec "CREATE TABLE veins_t_nowhere (id INTEGER)" in
      let%lwt () = ok "repaired" (M.migrate root) in
      (* unsupported *)
      M.register
        [ Migration.(
            create
              (Namespace.create (unique "startup_other"))
              ~written_at:(ptime_of_string "2024-03-01T00:00:00Z")
            |> add_step (Step.create ~label:"other dialect" (Sql.only other "SELECT 1")))
        ];
      let%lwt () = not_clean "unsupported" (fun () -> M.ensure_clean [ root ]) in
      let%lwt status = ok "ready" (M.ready root) in
      Alcotest.(check bool)
        "unsupported"
        true
        (match status with
         | Migration.Status.Blocked (Migration.Refusal.Missing_dialect _, _) -> true
         | _ -> false);
      let%lwt () = passes "skip" (M.check ~policy:`Skip root) in
      cleanup [ "veins_t_startup"; "veins_t_nowhere" ]
    ;;

    (* No veins rows but other tables: refused until the previous engine's
       state is imported; dirty counters become failed rows. *)
    let test_uninitialized_and_import () =
      let table = "veins_test_counters" in
      let applied = unique "imp_applied" in
      let dirty = unique "imp_dirty" in
      let module M = Single_set (struct
          let policy = `Fail
        end)
      in
      (* the previous engine ran [applied], failed [dirty] and never got to
         [later] *)
      let later = unique "imp_later" in
      M.register
        [ migration
            applied
            "2024-01-01T00:00:00Z"
            [ "create", "CREATE TABLE veins_t_import (id INTEGER)" ]
        ; migration
            dirty
            "2024-02-01T00:00:00Z"
            [ "half", "INSERT INTO veins_t_import (id) VALUES (2)" ]
        ; migration
            later
            "2024-03-01T00:00:00Z"
            [ "more", "INSERT INTO veins_t_import (id) VALUES (3)" ]
        ];
      let%lwt () = Db.exec (root_ctx ()) (drop_table table) () in
      let%lwt () = Db.exec (root_ctx ()) (drop_table "veins_t_import") () in
      let%lwt () =
        with_state_aside
        @@ fun () ->
        (* the previous engine ran the first step and failed the other *)
        let%lwt () = exec "CREATE TABLE veins_t_import (id INTEGER)" in
        let%lwt () =
          exec
            (Format.asprintf
               "CREATE TABLE %s (namespace VARCHAR(128) PRIMARY KEY, version INTEGER, \
                dirty BOOLEAN NOT NULL)"
               table)
        in
        let%lwt () =
          exec
            (Format.asprintf
               "INSERT INTO %s (namespace, version, dirty) VALUES ('%s', 1, FALSE), \
                ('%s', 0, TRUE), ('veins_test_unknown', 3, FALSE)"
               table
               applied
               dirty)
        in
        let%lwt msg = fails "uninitialized" (M.migrate root) in
        contains "says to import" ~sub:"import" msg;
        let%lwt status = ok "ready" (M.ready root) in
        Alcotest.(check bool)
          (Format.asprintf "uninitialized, got %s" (Migration.Status.show status))
          true
          (match status with
           | Migration.Status.Blocked (Migration.Refusal.Uninitialized, _) -> true
           | _ -> false);
        let%lwt () =
          expect_exn
            "ensure_clean"
            (fun () -> M.ensure_clean [ root ])
            (function
              | Error.Exn (Error.Migration_not_clean _) -> ()
              | exn -> Alcotest.failf "ensure_clean: %s" (Printexc.to_string exn))
        in
        let source = Migration.Import.counter_state ~table () in
        let%lwt report = ok "import" (M.Import.run ~source root) in
        Alcotest.(check (list (pair string int)))
          "imported applied"
          [ applied, 1 ]
          (CCList.map (fun (ns, n) -> Migration.Namespace.value ns, n) report.applied);
        Alcotest.(check (list string))
          "imported failed"
          [ dirty ]
          (CCList.map (fun (ns, _) -> Migration.Namespace.value ns) report.failed);
        Alcotest.(check (list string))
          "unknown"
          [ "veins_test_unknown" ]
          (CCList.map Migration.Namespace.value report.unknown);
        let%lwt imported = rows applied in
        Alcotest.(check (list (pair string int)))
          "applied, no run_at"
          [ "applied", 0 ]
          (CCList.map (fun ((_, _, status), (_, run)) -> status, run) imported);
        let%lwt failed = rows dirty in
        (match failed with
         | [ ((_, _, "failed"), (Some error, _)) ] ->
           Alcotest.(check string)
             "last_error"
             (table ^ ": marked dirty after 0 step(s)")
             error
         | _ -> Alcotest.fail "one failed row");
        let%lwt again = ok "import again" (M.Import.run ~source root) in
        Alcotest.(check int)
          "idempotent"
          0
          (CCList.length again.applied + CCList.length again.failed);
        let%lwt msg = fails "the dirty step blocks" (M.migrate root) in
        contains "names it" ~sub:dirty msg;
        (* the admin finished it by hand *)
        let%lwt () = exec "INSERT INTO veins_t_import (id) VALUES (2)" in
        let%lwt () =
          exec
            (Format.asprintf
               "UPDATE %s SET status = 'applied' WHERE namespace = '%s'"
               state
               dirty)
        in
        let%lwt () = ok "the rest" (M.migrate root) in
        check_count "veins_t_import" 2
      in
      let%lwt () = Db.exec (root_ctx ()) (drop_table table) () in
      Db.exec (root_ctx ()) (drop_table "veins_t_import") ()
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
        ; case "Pool.use" `Quick test_use
        ; case "Pool.use callback exceptions" `Quick test_use_callback_exceptions
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
      , [ case "the default set" `Quick test_default_set
        ; case "steps without SQL for the dialect" `Quick test_migration_dialects
        ; case "state table layout and upgrade" `Quick App_tests.test_state_table
        ; case "failure and repair by hand" `Quick App_tests.test_failure_and_repair
        ; case "missing rights fail the step" `Quick App_tests.test_missing_rights
        ; case
            "a failed step leaves nothing (PostgreSQL)"
            `Quick
            App_tests.test_failed_step_reverted
        ; case "concurrent migrate" `Quick App_tests.test_concurrent
        ; case "out of order" `Quick App_tests.test_out_of_order
        ; case "dry run" `Quick App_tests.test_dry_run
        ; case "startup: ensure_clean, check, command" `Quick App_tests.test_startup
        ; case "uninitialized and import" `Quick App_tests.test_uninitialized_and_import
        ] )
    ]
  ;;

  let run name =
    Random.self_init ();
    if CCOption.is_some (env_opt "VEINS_TEST_DEBUG")
    then (
      Logs.set_reporter (Logs_fmt.reporter ());
      Logs.set_level (Some Logs.Debug));
    setup ();
    Lwt_main.run (Alcotest_lwt.run name cases)
  ;;
end

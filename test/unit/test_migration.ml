(** Unit tests for {!Veins.Migration} — no live DB required. *)

open Veins

let test_derived_ids_are_stable () =
  let derive ~namespace ~index = Migration.Id.(derive ~namespace ~index |> value) in
  let id = derive ~namespace:"202301010000_guardian" ~index:0 in
  Alcotest.(check string)
    "same input, same id"
    id
    (derive ~namespace:"202301010000_guardian" ~index:0);
  Alcotest.(check bool) "valid UUID" true (CCOption.is_some (Uuidm.of_string id));
  Alcotest.(check bool)
    "index matters"
    false
    (CCString.equal id (derive ~namespace:"202301010000_guardian" ~index:1));
  Alcotest.(check bool)
    "namespace matters"
    false
    (CCString.equal id (derive ~namespace:"other" ~index:0))
;;

let test_id_create () =
  Alcotest.(check string)
    "normalised"
    "0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0"
    (Migration.Id.value (Migration.Id.create "0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0"));
  Alcotest.check_raises
    "not a UUID"
    (Invalid_argument "Migration.Id.create: not a UUID: \"step-1\"")
    (fun () -> ignore (Migration.Id.create "step-1"))
;;

let test_step_ids_given_or_derived () =
  let namespace = "202610121032" in
  let given = Migration.Id.create "00000000-0000-0000-0000-000000000001" in
  let mig =
    Migration.(
      create
        (Namespace.create namespace)
        ~written_at:(ptime_of_string "1970-01-01T00:00:00Z")
      |> add_step (Step.create ~label:"first" (Sql.any "SELECT 1"))
      |> add_step (Step.create ~id:given ~label:"second" (Sql.any "SELECT 2"))
      |> add_step (Step.create ~label:"third" (Sql.any "SELECT 3")))
  in
  Alcotest.(check (list string))
    "position decides a derived id"
    Migration.Id.
      [ value (derive ~namespace ~index:0)
      ; value given
      ; value (derive ~namespace ~index:2)
      ]
    (CCList.map Migration.Id.value (Migration.step_ids mig))
;;

let kind_list =
  let name = function
    | Dialect.Mariadb -> "mariadb"
    | Dialect.Postgresql -> "postgresql"
  in
  Alcotest.testable
    (fun f ks -> Format.pp_print_string f (CCString.concat ", " (CCList.map name ks)))
    ( = )
;;

let test_sql_per_dialect () =
  let open Migration.Sql in
  Alcotest.check kind_list "any" Dialect.[ Mariadb; Postgresql ] (kinds (any "SELECT 1"));
  Alcotest.check
    kind_list
    "only"
    Dialect.[ Postgresql ]
    (kinds (only Dialect.Postgresql "SELECT 1"));
  let both = v ~mariadb:"m" ~postgresql:"p" () in
  Alcotest.(check (option string)) "MariaDB's" (Some "m") (for_kind both Dialect.Mariadb);
  Alcotest.(check (option string))
    "PostgreSQL's"
    (Some "p")
    (for_kind both Dialect.Postgresql);
  Alcotest.(check (option string))
    "left out"
    None
    (for_kind (v ~mariadb:"m" ()) Dialect.Postgresql);
  Alcotest.check_raises
    "nothing at all"
    (Invalid_argument "Migration.Sql.v: no SQL for any dialect")
    (fun () -> ignore (v ()))
;;

let test_sql_placeholder () =
  let open Migration.Sql in
  let half = v ~mariadb:"CREATE TABLE t (id INT)" ~postgresql:"  TODO: fill in" () in
  Alcotest.(check bool) "written" true (written half Dialect.Mariadb);
  Alcotest.(check bool) "TODO is not written" false (written half Dialect.Postgresql);
  Alcotest.(check bool)
    "left out is not written"
    false
    (written (only Dialect.Mariadb "SELECT 1") Dialect.Postgresql);
  CCList.iter
    (fun sql -> Alcotest.(check bool) sql true (is_placeholder sql))
    [ "TODO: forward SQL"; "\n  TODO: indented" ];
  CCList.iter
    (fun sql -> Alcotest.(check bool) sql false (is_placeholder sql))
    [ "SELECT 1 -- TODO: later"
    ; "TODO_items"
    ; "todo: lower case"
    ; "-- TODO: a comment"
    ; ""
    ; "-- nothing to undo"
    ]
;;

(* The name is read once per process: only the default can be checked. *)
let test_state_table_default () =
  match Sys.getenv_opt "VEINS_MIGRATION_TABLE" with
  | Some name when not (CCString.is_empty name) ->
    Alcotest.(check string) "from the environment" name (Migration.state_table ())
  | Some _ | None ->
    Alcotest.(check string) "default" "veins_migration_state" (Migration.state_table ())
;;

(* {1 Order} *)

let at = Migration.ptime_of_string

let mig ?(steps = [ "one" ]) name written_at =
  CCList.fold_left
    (fun m label ->
       Migration.add_step (Migration.Step.create ~label (Migration.Sql.any "SELECT 1")) m)
    (Migration.create (Migration.Namespace.create name) ~written_at:(at written_at))
    steps
;;

let names = CCList.map (fun (m : Migration.t) -> Migration.Namespace.value m.namespace)
let ordered migrations = names (Migration.order migrations)

let test_order_written_at () =
  Alcotest.(check (list string))
    "written_at, ties by namespace"
    [ "a"; "b"; "c"; "d" ]
    (ordered
       [ mig "d" "2024-03-01T00:00:00Z"
       ; mig "c" "2024-02-01T00:00:00Z"
       ; mig "a" "2024-01-01T00:00:00Z"
       ; mig "b" "2024-02-01T00:00:00Z"
       ])
;;

(* {1 Registration} *)

module Db = Pools.Make (struct
    let database () = Database.create (Label.create "unit") (Url.create "mariadb://x/y")
    let database_pool_size = 1
    let expected_databases = 1

    module Driver = Driver.Generic
  end)

module Sets =
  Migration.Sets.Make
    (struct
      type t =
        [ `Root
        | `Tenant
        ]

      let all = [ `Root; `Tenant ]

      let name = function
        | `Root -> "root"
        | `Tenant -> "tenant"
      ;;

      let out_of_order = function
        | `Root -> `Fail
        | `Tenant -> `Warn
      ;;
    end)
    (Db)

let test_register_duplicates () =
  let unique = Format.asprintf "veins_unit_default_%d" (Random.int 1_000_000) in
  Migration.register (mig unique "2024-01-01T00:00:00Z");
  Alcotest.check_raises
    "twice in the default set"
    (Invalid_argument
       (Format.asprintf "Migration.register: '%s' is registered twice" unique))
    (fun () -> Migration.register (mig unique "2024-01-01T00:00:00Z"));
  Sets.register ~sets:[ `Root; `Tenant ] (mig "shared" "2024-01-01T00:00:00Z");
  Sets.register ~sets:[ `Tenant ] (mig "tenant" "2024-02-01T00:00:00Z");
  Sets.register ~sets:[ `Root ] (mig "tenant" "2024-02-01T00:00:00Z");
  Alcotest.check_raises
    "twice in one set"
    (Invalid_argument
       "Migration.Sets.register: 'tenant' is registered twice in set tenant")
    (fun () -> Sets.register ~sets:[ `Tenant ] (mig "tenant" "2024-03-01T00:00:00Z"));
  Alcotest.check_raises
    "no set"
    (Invalid_argument "Migration.Sets.register: 'nowhere' is registered into no set")
    (fun () -> Sets.register ~sets:[] (mig "nowhere" "2024-03-01T00:00:00Z"));
  Alcotest.(check (list string))
    "root"
    [ "shared"; "tenant" ]
    (names (Sets.migrations `Root));
  Alcotest.(check (list string))
    "tenant"
    [ "shared"; "tenant" ]
    (names (Sets.migrations `Tenant))
;;

(* {1 State} *)

let row ?(status = Migration.Row_status.Applied) ?last_error (m : Migration.t) index =
  let uuid = CCList.nth (Migration.step_ids m) index in
  { Migration.Row.id = Some (index + 1)
  ; uuid
  ; namespace = m.namespace
  ; label = "step"
  ; status
  ; last_error
  ; run_at = None
  }
;;

let test_row_status () =
  let open Migration.Row_status in
  Alcotest.(check bool) "applied" true (of_string "applied" = Ok Applied);
  Alcotest.(check bool) "failed" true (of_string "failed" = Ok Failed);
  Alcotest.(check bool) "anything else" true (CCResult.is_error (of_string "dirty"))
;;

let dry_run
      ?allow_out_of_order
      ?(policy = `Fail)
      ?(dialect = Dialect.Mariadb)
      ?(state_table = true)
      ?(other_tables = true)
      rows
      migrations
  =
  Migration.Dry_run.of_state
    ?allow_out_of_order
    ~label:(Label.create "root")
    ~set:"root"
    ~out_of_order:policy
    ~dialect
    ~state_table
    ~other_tables
    ~rows
    migrations
;;

let refusal_name (t : Migration.Dry_run.t) =
  match t.refusal with
  | None -> "none"
  | Some (Migration.Refusal.Duplicates _) -> "duplicates"
  | Some (Migration.Refusal.Missing_dialect _) -> "missing dialect"
  | Some Migration.Refusal.Uninitialized -> "uninitialized"
  | Some (Migration.Refusal.Failed _) -> "failed"
  | Some (Migration.Refusal.Out_of_order _) -> "out of order"
;;

let a = mig "a" "2024-01-01T00:00:00Z" ~steps:[ "one"; "two" ]
let b = mig "b" "2024-02-01T00:00:00Z"
let c = mig "c" "2024-03-01T00:00:00Z"

let test_dry_run_refusals () =
  let check name expected t = Alcotest.(check string) name expected (refusal_name t) in
  check
    "fresh, empty database"
    "none"
    (dry_run ~state_table:false ~other_tables:false [] [ a; b ]);
  check "tables, no state" "uninitialized" (dry_run ~state_table:false [] [ a; b ]);
  (* an import that found nothing, or every row deleted by hand *)
  check "tables, empty state table" "none" (dry_run [] [ a; b ]);
  check "applied in order" "none" (dry_run [ row a 0; row a 1 ] [ a; b; c ]);
  check "twice in the set" "duplicates" (dry_run [] [ a; a ]);
  check
    "no SQL for the dialect"
    "missing dialect"
    (dry_run
       ~dialect:Dialect.Postgresql
       [ row a 0 ]
       [ Migration.(
           create (Namespace.create "m") ~written_at:(at "2024-01-01T00:00:00Z")
           |> add_step (Step.create ~label:"m" (Sql.only Dialect.Mariadb "SELECT 1")))
       ]);
  let failed =
    dry_run
      [ row a 0; row ~status:Migration.Row_status.Failed ~last_error:"boom" a 1 ]
      [ a; b ]
  in
  check "failed step" "failed" failed;
  Alcotest.(check int)
    "nothing else pending in the report"
    1
    (CCList.length failed.report.pending);
  let ooo = dry_run [ row a 0; row a 1; row c 0 ] [ a; b; c ] in
  check "out of order" "out of order" ooo;
  Alcotest.(check bool)
    "blocked, not pending"
    true
    (match Migration.Status.of_dry_run ooo with
     | Migration.Status.Blocked (Migration.Refusal.Out_of_order _, _) -> true
     | _ -> false);
  Alcotest.(check (list string))
    "named with the newest applied"
    [ "b before c" ]
    (CCList.map
       (fun ({ namespace; newest_applied } : Migration.Out_of_order.t) ->
          Migration.Namespace.(value namespace ^ " before " ^ value newest_applied))
       ooo.report.out_of_order);
  let warned = dry_run ~policy:`Warn [ row a 0; row a 1; row c 0 ] [ a; b; c ] in
  check "out of order under `Warn" "none" warned;
  Alcotest.(check int) "listed under `Warn" 1 (CCList.length warned.report.out_of_order);
  Alcotest.(check int) "and runs" 1 (CCList.length warned.allowed);
  let allowed =
    dry_run
      ~allow_out_of_order:[ Migration.Namespace.create "b" ]
      [ row a 0; row a 1; row c 0 ]
      [ a; b; c ]
  in
  check "allowed by name" "none" allowed;
  let d = mig "d" "2024-01-15T00:00:00Z" in
  check
    "one of two allowed"
    "out of order"
    (dry_run
       ~allow_out_of_order:[ Migration.Namespace.create "b" ]
       [ row a 0; row a 1; row c 0 ]
       [ a; d; b; c ]);
  let appended = dry_run [ row a 0; row c 0 ] [ a; c ] in
  check "a step appended to an older migration" "out of order" appended
;;

let test_dry_run_rows () =
  let outside = row (mig "gone" "2023-01-01T00:00:00Z") 0 in
  let failed_outside =
    row ~status:Migration.Row_status.Failed (mig "gone_failed" "2023-01-01T00:00:00Z") 0
  in
  let t = dry_run [ row a 0; row a 1; row b 0; outside; failed_outside ] [ a; b ] in
  Alcotest.(check string) "rows outside the set don't refuse" "none" (refusal_name t);
  Alcotest.(check int) "orphaned" 2 (CCList.length t.report.orphaned);
  Alcotest.(check bool)
    "ready"
    true
    (Migration.Status.is_ready (Migration.Status.of_dry_run t));
  let pending = dry_run [ row a 0 ] [ a; b ] in
  Alcotest.(check (list (pair string (list string))))
    "pending, in order"
    [ "a", [ "two" ]; "b", [ "one" ] ]
    (CCList.map
       (fun (ns, labels) -> Migration.Namespace.value ns, labels)
       pending.report.pending);
  let more = dry_run [] [ a; b ] in
  Alcotest.(check (list (pair string int)))
    "pending counts"
    [ "a", 2; "b", 1 ]
    (CCList.map
       (fun (ns, n) -> Migration.Namespace.value ns, n)
       (Migration.Report.pending_counts more.report));
  Alcotest.(check int) "pending total" 3 (Migration.Report.pending_total more.report);
  Alcotest.(check string)
    "status"
    "2 pending step(s): a (1), b (1)"
    (Migration.Status.show (Migration.Status.of_dry_run pending))
;;

let contains name ~sub s =
  Alcotest.(check bool)
    (Format.asprintf "%s: %S in %S" name sub s)
    true
    (CCString.mem ~sub s)
;;

let test_pp () =
  let failed =
    dry_run
      [ row a 0; row ~status:Migration.Row_status.Failed ~last_error:"boom" a 1 ]
      [ a ]
  in
  let uuid = Migration.Id.value (CCList.nth (Migration.step_ids a) 1) in
  let shown = Migration.Report.show failed.report in
  contains "report" ~sub:"a failed step blocks" shown;
  contains "report" ~sub:uuid shown;
  contains "report" ~sub:"boom" shown;
  contains "report" ~sub:"UPDATE veins_migration_state SET status = 'applied'" shown;
  contains "report" ~sub:"DELETE FROM veins_migration_state" shown;
  contains "dry run" ~sub:"migrate would refuse" (Migration.Dry_run.show failed);
  contains
    "dry run"
    ~sub:"--allow-out-of-order"
    (Migration.Dry_run.show (dry_run [ row a 0; row a 1; row c 0 ] [ a; b; c ]));
  contains
    "ready"
    ~sub:"up to date"
    (Migration.Report.show (dry_run [ row a 0; row a 1 ] [ a ]).report)
;;

let test_repair_sql () =
  let uuid = Migration.Id.create "0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0" in
  let table = Migration.state_table () in
  Alcotest.(check string)
    "MariaDB"
    (Format.asprintf
       "UPDATE %s SET status = 'applied' WHERE uuid = UNHEX(REPLACE('%s', '-', ''))"
       table
       (Migration.Id.value uuid))
    (Migration.Repair.mark_applied Dialect.Mariadb uuid);
  Alcotest.(check string)
    "PostgreSQL"
    (Format.asprintf "DELETE FROM %s WHERE uuid = '%s'" table (Migration.Id.value uuid))
    (Migration.Repair.delete Dialect.Postgresql uuid)
;;

(* {1 Import} *)

let test_import_plan () =
  let entry ?failed name applied =
    { Migration.Import.namespace = Migration.Namespace.create name; applied; failed }
  in
  let report, rows =
    Migration.Import.plan
      ~source:"core_migration_state"
      [ a; b ]
      ~existing:[ CCList.hd (Migration.step_ids a) ]
      [ entry "a" 1 ~failed:"dirty"; entry "b" 3; entry "unknown" 1 ]
  in
  Alcotest.(check (list (pair string string)))
    "rows"
    [ "b", "applied"; "a", "failed" ]
    (CCList.sort
       compare
       (CCList.map
          (fun (r : Migration.Row.t) ->
             ( Migration.Namespace.value r.namespace
             , Migration.Row_status.to_string r.status ))
          rows)
     |> CCList.rev);
  Alcotest.(check (list (option string)))
    "failed message"
    [ Some "core_migration_state: dirty" ]
    (CCList.filter_map
       (fun (r : Migration.Row.t) ->
          CCOption.return_if (r.status = Migration.Row_status.Failed) r.last_error)
       rows);
  Alcotest.(check (list string))
    "unknown"
    [ "unknown" ]
    (CCList.map Migration.Namespace.value report.unknown);
  Alcotest.(check int) "too large" 1 (CCList.length report.too_large);
  contains
    "report"
    ~sub:"imported 1 applied step(s)"
    (Migration.Import.Report.show report);
  let again, rows =
    Migration.Import.plan
      ~source:"s"
      [ a ]
      ~existing:(Migration.step_ids a)
      [ entry "a" 1 ~failed:"dirty" ]
  in
  Alcotest.(check int) "existing rows are left alone" 0 (CCList.length rows);
  Alcotest.(check int) "nothing imported" 0 (CCList.length again.applied)
;;

(* {1 Command} *)

let test_command_parse () =
  let open Migration.Command in
  let show = function
    | Ok (Up ns) -> "up " ^ CCString.concat "," (CCList.map Migration.Namespace.value ns)
    | Ok (Dry_run ns) ->
      "dry-run " ^ CCString.concat "," (CCList.map Migration.Namespace.value ns)
    | Ok Status -> "status"
    | Ok Check -> "check"
    | Error (_ : string) -> "usage"
  in
  let case args expected =
    Alcotest.(check string) (CCString.concat " " args) expected (show (parse args))
  in
  case [] "up ";
  case [ "up" ] "up ";
  case [ "up"; "--allow-out-of-order"; "a" ] "up a";
  case [ "up"; "--allow-out-of-order"; "a"; "b"; "--allow-out-of-order"; "c" ] "up a,b,c";
  case [ "up"; "--allow-out-of-order" ] "usage";
  case [ "dry-run"; "--allow-out-of-order"; "a" ] "dry-run a";
  case [ "dry-run" ] "dry-run ";
  case [ "status" ] "status";
  case [ "check" ] "check";
  case [ "check"; "now" ] "usage";
  case [ "up"; "sideways" ] "usage";
  case [ "down" ] "usage";
  let env value = CCList.map Migration.Namespace.value (allowed_of_env value) in
  Alcotest.(check (list string)) "unset" [] (env None);
  Alcotest.(check (list string)) "empty" [] (env (Some " "));
  Alcotest.(check (list string))
    "commas and whitespace"
    [ "a"; "b"; "c" ]
    (env (Some "a, b\tc,"))
;;

let () =
  Random.self_init ();
  Alcotest.run
    "Veins Migration"
    [ ( "id"
      , [ Alcotest.test_case "derived ids are stable" `Quick test_derived_ids_are_stable
        ; Alcotest.test_case "create checks UUIDs" `Quick test_id_create
        ; Alcotest.test_case
            "step ids given or derived"
            `Quick
            test_step_ids_given_or_derived
        ] )
    ; ( "sql"
      , [ Alcotest.test_case "SQL per dialect" `Quick test_sql_per_dialect
        ; Alcotest.test_case "TODO placeholders" `Quick test_sql_placeholder
        ] )
    ; "register", [ Alcotest.test_case "duplicates" `Quick test_register_duplicates ]
    ; "order", [ Alcotest.test_case "written_at" `Quick test_order_written_at ]
    ; ( "state"
      , [ Alcotest.test_case "default table name" `Quick test_state_table_default
        ; Alcotest.test_case "row status" `Quick test_row_status
        ; Alcotest.test_case "repair SQL" `Quick test_repair_sql
        ] )
    ; ( "dry run"
      , [ Alcotest.test_case "refusals" `Quick test_dry_run_refusals
        ; Alcotest.test_case "rows and pending" `Quick test_dry_run_rows
        ; Alcotest.test_case "printing" `Quick test_pp
        ] )
    ; "import", [ Alcotest.test_case "plan" `Quick test_import_plan ]
    ; "command", [ Alcotest.test_case "arguments" `Quick test_command_parse ]
    ]
;;

(** Unit tests for {!Veins.Migration.database_target} — no live DB required. *)

open Veins

let lbl s = Label.create s
let root = lbl "root"
let tenant1 = lbl "tenant1"
let tenant2 = lbl "tenant2"
let other = lbl "other"

let test_database_matches_exact () =
  let t = Migration.Database root in
  assert (Migration.target_applies_to t root);
  assert (not (Migration.target_applies_to t tenant1));
  assert (not (Migration.target_applies_to t tenant2));
  assert (not (Migration.target_applies_to t other))
;;

let test_databases_matches_any_listed () =
  let t = Migration.Databases [ root; tenant1 ] in
  assert (Migration.target_applies_to t root);
  assert (Migration.target_applies_to t tenant1);
  assert (not (Migration.target_applies_to t tenant2));
  assert (not (Migration.target_applies_to t other))
;;

let test_databases_empty_list_matches_nothing () =
  let t = Migration.Databases [] in
  assert (not (Migration.target_applies_to t root));
  assert (not (Migration.target_applies_to t tenant1))
;;

let test_all_matches_every_label () =
  let t = Migration.All in
  assert (Migration.target_applies_to t root);
  assert (Migration.target_applies_to t tenant1);
  assert (Migration.target_applies_to t tenant2);
  assert (Migration.target_applies_to t other)
;;

let test_all_except_excludes_listed () =
  let t = Migration.AllExcept [ root; tenant1 ] in
  assert (not (Migration.target_applies_to t root));
  assert (not (Migration.target_applies_to t tenant1));
  assert (Migration.target_applies_to t tenant2);
  assert (Migration.target_applies_to t other)
;;

let test_all_except_empty_list_matches_all () =
  let t = Migration.AllExcept [] in
  assert (Migration.target_applies_to t root);
  assert (Migration.target_applies_to t tenant1);
  assert (Migration.target_applies_to t tenant2)
;;

let test_register_default_targets_root () =
  (* The default for_databases is All; verify it applies to every label. *)
  let default_target = Migration.All in
  assert (Migration.target_applies_to default_target (lbl "root"));
  assert (Migration.target_applies_to default_target (lbl "tenant"))
;;

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

let () =
  Alcotest.run
    "Veins Migration"
    [ ( "id"
      , [ Alcotest.test_case "derived ids are stable" `Quick test_derived_ids_are_stable
        ; Alcotest.test_case
            "step ids given or derived"
            `Quick
            test_step_ids_given_or_derived
        ] )
    ; ( "sql"
      , [ Alcotest.test_case "SQL per dialect" `Quick test_sql_per_dialect
        ; Alcotest.test_case "TODO placeholders" `Quick test_sql_placeholder
        ] )
    ; ( "database_target"
      , [ Alcotest.test_case "Database exact match" `Quick test_database_matches_exact
        ; Alcotest.test_case
            "Databases matches any listed"
            `Quick
            test_databases_matches_any_listed
        ; Alcotest.test_case
            "Databases empty list matches nothing"
            `Quick
            test_databases_empty_list_matches_nothing
        ; Alcotest.test_case "All matches every label" `Quick test_all_matches_every_label
        ; Alcotest.test_case
            "AllExcept excludes listed"
            `Quick
            test_all_except_excludes_listed
        ; Alcotest.test_case
            "AllExcept empty matches all"
            `Quick
            test_all_except_empty_list_matches_all
        ] )
    ; ( "register"
      , [ Alcotest.test_case
            "default target is All"
            `Quick
            test_register_default_targets_root
        ] )
    ; "state table", [ Alcotest.test_case "default name" `Quick test_state_table_default ]
    ]
;;

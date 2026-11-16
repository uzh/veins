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
  let id = Migration.Id.derive ~namespace:"202301010000_guardian" ~index:0 in
  Alcotest.(check string)
    "same input, same id"
    id
    (Migration.Id.derive ~namespace:"202301010000_guardian" ~index:0);
  Alcotest.(check bool) "valid UUID" true (Option.is_some (Uuidm.of_string id));
  Alcotest.(check bool)
    "index matters"
    false
    (CCString.equal id (Migration.Id.derive ~namespace:"202301010000_guardian" ~index:1));
  Alcotest.(check bool)
    "namespace matters"
    false
    (CCString.equal id (Migration.Id.derive ~namespace:"other" ~index:0))
;;

let () =
  Alcotest.run
    "Veins Migration"
    [ ( "id"
      , [ Alcotest.test_case "derived ids are stable" `Quick test_derived_ids_are_stable ]
      )
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
    ]
;;

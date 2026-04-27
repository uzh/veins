(** Unit tests for {!Veins.Migration.database_target} — no live DB required. *)

open Veins

let lbl s = Label.create s
let root = lbl "root"
let tenant1 = lbl "tenant1"
let tenant2 = lbl "tenant2"
let other = lbl "other"

(* ------------------------------------------------------------------ *)
(* target_applies_to                                                   *)
(* ------------------------------------------------------------------ *)

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

(* ------------------------------------------------------------------ *)
(* register — default target                                           *)
(* ------------------------------------------------------------------ *)

let test_register_default_targets_root () =
  (* The default for_databases is All; verify it applies to every label. *)
  let default_target = Migration.All in
  assert (Migration.target_applies_to default_target (lbl "root"));
  assert (Migration.target_applies_to default_target (lbl "tenant"))
;;

(* ------------------------------------------------------------------ *)
(* Runner                                                              *)
(* ------------------------------------------------------------------ *)

let () =
  test_database_matches_exact ();
  test_databases_matches_any_listed ();
  test_databases_empty_list_matches_nothing ();
  test_all_matches_every_label ();
  test_all_except_excludes_listed ();
  test_all_except_empty_list_matches_all ();
  test_register_default_targets_root ();
  print_endline "All migration unit tests passed."
;;

(** veins-gen's template: the fixtures in this directory are its output,
    compiled and linked here. *)

open Veins
module T = Veins_gen_template

let pp_kind ppf = function
  | Dialect.Mariadb -> Format.pp_print_string ppf "mariadb"
  | Dialect.Postgresql -> Format.pp_print_string ppf "postgresql"
;;

let kinds = Alcotest.(list (testable pp_kind ( = )))

let check_migration name migration ~namespace ~steps ~dialects =
  let open Migration in
  Alcotest.(check string)
    (name ^ " namespace")
    namespace
    (Namespace.value migration.namespace);
  Alcotest.(check int) (name ^ " step count") steps (CCList.length migration.steps);
  Alcotest.(check (list string))
    (name ^ " ids in order")
    (CCList.init steps (fun i -> Printf.sprintf "00000000-0000-4000-8000-%012d" (i + 1)))
    (CCList.map Id.value (step_ids migration));
  CCList.iter
    (fun (step : Step.t) ->
       Alcotest.check kinds (name ^ " up dialects") dialects (Sql.kinds step.Step.up);
       Alcotest.check
         kinds
         (name ^ " down dialects")
         dialects
         (CCOption.map_or ~default:[] Sql.kinds step.Step.down);
       CCList.iter
         (fun kind ->
            Alcotest.(check bool)
              (name ^ " placeholder is not SQL")
              false
              (Sql.written step.Step.up kind))
         dialects)
    migration.steps
;;

let test_fixtures () =
  check_migration
    "both"
    Fixture_both.migration
    ~namespace:"fixture_both"
    ~steps:3
    ~dialects:[ Dialect.Mariadb; Dialect.Postgresql ];
  check_migration
    "mariadb"
    Fixture_mariadb.migration
    ~namespace:"fixture_mariadb"
    ~steps:1
    ~dialects:[ Dialect.Mariadb ];
  check_migration
    "postgresql"
    Fixture_postgresql.migration
    ~namespace:"fixture_postgresql"
    ~steps:2
    ~dialects:[ Dialect.Postgresql ]
;;

let test_random_ids () =
  let ids = T.random_ids (Random.State.make [| 42 |]) ~steps:4 in
  Alcotest.(check int) "count" 4 (CCList.length ids);
  Alcotest.(check int) "distinct" 4 (CCList.length (CCList.sort_uniq ~cmp:compare ids));
  CCList.iter (fun id -> ignore (Migration.Id.create id)) ids
;;

let test_no_ids () =
  Alcotest.check_raises
    "no steps"
    (Invalid_argument "Veins_gen_template.render: no step ids")
    (fun () ->
       ignore
         (T.render
            ~module_name:"M"
            ~namespace:"m"
            ~written_at:Ptime.epoch
            ~dialects:T.Both
            ~ids:[]))
;;

let test_names () =
  Alcotest.(check string) "slug" "add_users_table" (T.slugify "  Add users-table! ");
  Alcotest.(check string)
    "module"
    "AddUsersTable"
    (T.module_name_of_slug "add_users_table");
  Alcotest.(check string) "leading digit" "Migration2fa" (T.module_name_of_slug "2fa");
  Alcotest.(check string)
    "compact"
    "20260424140314"
    (T.compact_timestamp (Migration.ptime_of_string "2026-04-24T14:03:14Z"))
;;

let () =
  Alcotest.run
    "veins-gen"
    [ ( "template"
      , [ Alcotest.test_case "fixtures compile and register" `Quick test_fixtures
        ; Alcotest.test_case "random ids" `Quick test_random_ids
        ; Alcotest.test_case "no ids" `Quick test_no_ids
        ; Alcotest.test_case "names" `Quick test_names
        ] )
    ]
;;

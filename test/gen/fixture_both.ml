(** Migration: FixtureBoth *)

open Veins

(* Steps run in the order [migration] adds them. Once a step is deployed, never
   change its id or [up], or remove it: append a new step instead. Leave out the
   SQL of a dialect the application never runs on, in [up] and [down] alike. The
   runner refuses to apply a step whose [up] SQL is still a TODO, and to revert
   a migration while a [down] is: write it, or drop [~down] if the step can't be
   reverted. *)

let step_1 =
  let up =
    Migration.Sql.v
      ~mariadb:{sql|TODO: forward SQL|sql}
      ~postgresql:{sql|TODO: forward SQL|sql}
      ()
  in
  let down =
    Migration.Sql.v
      ~mariadb:{sql|TODO: reverse SQL|sql}
      ~postgresql:{sql|TODO: reverse SQL|sql}
      ()
  in
  Migration.Step.create
    ~id:(Migration.Id.create "00000000-0000-4000-8000-000000000001")
    ~label:"TODO: describe step 1"
    ~down
    up
;;

let step_2 =
  let up =
    Migration.Sql.v
      ~mariadb:{sql|TODO: forward SQL|sql}
      ~postgresql:{sql|TODO: forward SQL|sql}
      ()
  in
  let down =
    Migration.Sql.v
      ~mariadb:{sql|TODO: reverse SQL|sql}
      ~postgresql:{sql|TODO: reverse SQL|sql}
      ()
  in
  Migration.Step.create
    ~id:(Migration.Id.create "00000000-0000-4000-8000-000000000002")
    ~label:"TODO: describe step 2"
    ~down
    up
;;

let step_3 =
  let up =
    Migration.Sql.v
      ~mariadb:{sql|TODO: forward SQL|sql}
      ~postgresql:{sql|TODO: forward SQL|sql}
      ()
  in
  let down =
    Migration.Sql.v
      ~mariadb:{sql|TODO: reverse SQL|sql}
      ~postgresql:{sql|TODO: reverse SQL|sql}
      ()
  in
  Migration.Step.create
    ~id:(Migration.Id.create "00000000-0000-4000-8000-000000000003")
    ~label:"TODO: describe step 3"
    ~down
    up
;;

let migration =
  let namespace = Migration.Namespace.create "fixture_both" in
  let written_at = Migration.ptime_of_string "2026-04-24T14:03:14Z" in
  Migration.create namespace ~written_at
  |> Migration.add_step step_1
  |> Migration.add_step step_2
  |> Migration.add_step step_3
;;

let () = Migration.register migration

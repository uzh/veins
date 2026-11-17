(** Migration: FixturePostgresql *)

open Veins

(* Steps run in the order [migration] adds them. Once a step is deployed, never
   change or remove it: append a new step instead. The runner refuses to apply
   a step whose SQL is still a TODO. *)

let step_1 =
  let up = Migration.Sql.only Dialect.Postgresql {sql|TODO: forward SQL|sql} in
  let down = Migration.Sql.only Dialect.Postgresql {sql|TODO: reverse SQL|sql} in
  Migration.Step.create
    ~id:(Migration.Id.create "00000000-0000-4000-8000-000000000001")
    ~label:"TODO: describe step 1"
    ~down
    up
;;

let step_2 =
  let up = Migration.Sql.only Dialect.Postgresql {sql|TODO: forward SQL|sql} in
  let down = Migration.Sql.only Dialect.Postgresql {sql|TODO: reverse SQL|sql} in
  Migration.Step.create
    ~id:(Migration.Id.create "00000000-0000-4000-8000-000000000002")
    ~label:"TODO: describe step 2"
    ~down
    up
;;

let migration =
  let namespace = Migration.Namespace.create "fixture_postgresql" in
  let written_at = Migration.ptime_of_string "2026-04-24T14:03:14Z" in
  Migration.create namespace ~written_at
  |> Migration.add_step step_1
  |> Migration.add_step step_2
;;

let () = Migration.register migration

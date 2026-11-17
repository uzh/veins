(** Migration: FixtureMariadb *)

open Veins

(* Steps run in the order [migration] adds them. Once a step is deployed, never
   change or remove it: append a new step instead. *)

let step_1 =
  let up =
    Migration.Sql.only
      Dialect.Mariadb
      {sql|
        TODO: forward SQL
      |sql}
  in
  let down =
    Migration.Sql.only
      Dialect.Mariadb
      {sql|
        TODO: reverse SQL
      |sql}
  in
  Migration.Step.create
    ~id:(Migration.Id.create "00000000-0000-4000-8000-000000000001")
    ~label:"TODO: describe step 1"
    ~down
    up
;;

let migration =
  let namespace = Migration.Namespace.create "fixture_mariadb" in
  let written_at = Migration.ptime_of_string "2026-04-24T14:03:14Z" in
  Migration.create namespace ~written_at |> Migration.add_step step_1
;;

let () = Migration.register migration

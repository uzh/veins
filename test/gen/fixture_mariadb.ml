(** Migration: FixtureMariadb *)

open Veins

(* Steps run in the order [migration] adds them, each on its own: write one
   statement per step where possible. Once a step is deployed, never change its
   id or SQL, or remove it: append a new step, or fix a mistake with a new
   migration (roll-forward only), keeping the previous release working. The
   runner refuses to apply a step whose SQL is still a TODO. Nothing references
   this module: link its library with [(library_flags (-linkall))], or the
   linker drops it and the migration never registers. *)

let step_1 =
  let up = Migration.Sql.only Dialect.Mariadb {sql|TODO: forward SQL|sql} in
  Migration.Step.create
    ~id:(Migration.Id.create "00000000-0000-4000-8000-000000000001")
    ~label:"TODO: describe step 1"
    up
;;

let migration =
  let namespace = Migration.Namespace.create "fixture_mariadb" in
  let written_at = Migration.ptime_of_string "2026-04-24T14:03:14Z" in
  Migration.create namespace ~written_at |> Migration.add_step step_1
;;

let () = Migration.register migration

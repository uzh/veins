(** Standalone migration module.

    Types and the global registry live at the top level.  Apply {!Make} to a
    pool module (the output of {!Pools.Make}) to get a runner with
    {!RunnerSig.run_all}, {!RunnerSig.up}, {!RunnerSig.down},
    {!RunnerSig.check}, {!RunnerSig.status}, and {!RunnerSig.pending}.

    {b Design principles}
    {ul
    {- Steps are tracked individually by UUID, not by a per-namespace
       version counter.  An already-applied step is always skipped,
       regardless of its position in the list.}
    {- Migrations are applied in ascending [written_at] order when calling
       {!RunnerSig.run_all}, so the apply order is deterministic regardless
       of the order modules call {!register}.}
    {- Steps within a migration are applied in list order (always append new
       steps at the end).}
    {- Migrations can target different databases.  Use [~for_database] to
       associate a migration with a specific {!Entity.Label.t}.  Omitting the
       argument defaults to [Label.create "root"].}
    {- Down migrations are optional.  A step whose [~down] is absent is
       irreversible; {!RunnerSig.down} will log a warning and skip it.}}

    {b Quick-start}
    {[
      module Db = Vena.Pools.Make (MyCfg)
      module M  = Vena.Migration.Make (Db)

      let () =
        Vena.Migration.register
          ~for_database:(Vena.Label.create "root")
          Vena.Migration.(
            empty
              (Namespace.create "my_app")
              ~written_at:(ptime_of_string "2024-01-15T10:00:00Z")
            |> add_step
                 (step
                    ~id:(Id.create "550e8400-e29b-41d4-a716-446655440001")
                    ~label:"create users table"
                    ~down:"DROP TABLE IF EXISTS users"
                    {|CREATE TABLE users (
                        id   INT          PRIMARY KEY AUTO_INCREMENT,
                        name VARCHAR(255) NOT NULL
                      )|})
          )

      let () =
        Db.Pool.initialize ();
        Lwt_main.run
          (let%lwt drifts = M.check (Vena.Label.create "root") () in
           (* drifts is [] when the DB is fully up to date *)
           match%lwt M.run_all (Vena.Label.create "root") () with
           | Ok ()   -> Lwt.return_unit
           | Error e -> failwith (Vena.Error.show e))
    ]}
*)

(** Parse an RFC 3339 string into [Ptime.t].  Raises [Invalid_argument] if
    the string is malformed.  Use for static authoring timestamps:
    [ptime_of_string "2024-01-15T10:00:00Z"]. *)
val ptime_of_string : string -> Ptime.t

(* ------------------------------------------------------------------ *)
(* Id / Namespace opaque types                                         *)
(* ------------------------------------------------------------------ *)

(** Opaque type for a step's stable identifier (UUID string). *)
module Id : sig
  type t

  val create : string -> t
  val value : t -> string
  val equal : t -> t -> bool
  val pp : Format.formatter -> t -> unit
  val show : t -> string
end

(** Opaque type for a migration's group name. *)
module Namespace : sig
  type t

  val create : string -> t
  val value : t -> string
  val equal : t -> t -> bool
  val pp : Format.formatter -> t -> unit
  val show : t -> string
end

(* ------------------------------------------------------------------ *)
(* Step                                                                *)
(* ------------------------------------------------------------------ *)

(** A single, individually-trackable migration step. *)
type step =
  { id : Id.t
        (** Stable UUID — must be globally unique across the entire
            application.  Used as the primary key in the migration-state
            table.  Choose a real UUID v4 at authoring time and never
            change it once the step has been deployed. *)
  ; label : string  (** Human-readable description (used in log output). *)
  ; up : string  (** SQL statement to apply this step (forward migration). *)
  ; down : string option
        (** SQL statement to revert this step.  [None] means the step is
            irreversible; {!RunnerSig.down} will log a warning and skip
            it. *)
  ; check_fk : bool
        (** When [false] the runner temporarily disables FK checks before
            executing [up] or [down].  Has no effect on dialects where
            {!Dialect.Sig.fk_checks_supported} is [false] (e.g.
            PostgreSQL). *)
  }

(** Build a [step].

    @param id       Stable UUID v4 wrapped in {!Id.t}.
    @param label    Human-readable description for log output.
    @param check_fk Defaults to [true].  Pass [false] to disable FK
                    checks around this step on dialects that support it
                    (MariaDB / MySQL only).
    @param down     Optional SQL to revert the step.
    @param up       (positional) SQL to apply the step. *)
val step
  :  id:Id.t
  -> label:string
  -> ?check_fk:bool
  -> ?down:string
  -> string
  -> step

(* ------------------------------------------------------------------ *)
(* Migration                                                           *)
(* ------------------------------------------------------------------ *)

(** A named, ordered group of migration steps. *)
type t =
  { namespace : Namespace.t
        (** Unique identifier for this migration group, e.g.
            [Namespace.create "my_app"].  Used as the [namespace] column
            in the migration-state table. *)
  ; written_at : Ptime.t
        (** Authoring timestamp used to sort migrations before applying.
            {!RunnerSig.run_all} sorts all registered migrations for a
            database label by [written_at] (ascending) before applying
            them, so the apply order is deterministic regardless of
            registration order. *)
  ; steps : step list
        (** Steps in timeline / dependency order.  Always {b append} new
            steps at the end — never re-order or remove already-deployed
            steps. *)
  }

(** Create an empty migration.
    @param written_at  Authoring timestamp.  Use {!ptime_of_string} for
                       static literals, e.g.
                       [ptime_of_string "2024-01-15T10:00:00Z"]. *)
val empty : Namespace.t -> written_at:Ptime.t -> t

(** Append [step] to the end of [migration.steps]. *)
val add_step : step -> t -> t

(* ------------------------------------------------------------------ *)
(* Global registry                                                     *)
(* ------------------------------------------------------------------ *)

(** Register [migration] so it will be applied to [for_database] when
    {!RunnerSig.run_all} is next called for that label.

    @param for_database  The database label this migration targets.
                         Defaults to [Entity.Label.create "root"]. *)
val register : ?for_database:Entity.Label.t -> t -> unit

(* ------------------------------------------------------------------ *)
(* Drift                                                               *)
(* ------------------------------------------------------------------ *)

(** A discrepancy between the in-process registry and the migration-state
    table in a database.  Returned by {!RunnerSig.check}. *)
type drift =
  | Pending of
      { namespace : Namespace.t
      ; pending_steps : int
      ; total_steps : int
      }
  | Orphaned of
      { namespace : Namespace.t
      ; step_ids : Id.t list
      }

(* ------------------------------------------------------------------ *)
(* Runner interface                                                    *)
(* ------------------------------------------------------------------ *)

(** Interface satisfied by the output of {!Make}. *)
module type RunnerSig = sig
  (** Apply all unapplied steps for every migration registered for
      [db_label] (in registration order).  Returns [Ok ()] when all steps
      are applied or already up to date.  Returns [Error _] on the first
      failure, leaving remaining migrations unattempted. *)
  val run_all : Entity.Label.t -> unit -> (unit, Error.t) Lwt_result.t

  (** Apply all unapplied steps in [migration] to [db_label].
      Already-applied steps (identified by their [id] UUID) are skipped.
      Returns [Error _] on the first step failure. *)
  val up : Entity.Label.t -> t -> (unit, Error.t) Lwt_result.t

  (** Revert all applied steps in [migration] from [db_label] in {b
      reverse} order.  Steps whose [down] is [None] are logged and
      skipped.  Returns [Error _] on the first failure. *)
  val down : Entity.Label.t -> t -> (unit, Error.t) Lwt_result.t

  (** Compare the in-process registry against the migration-state table
      and return every detected {!drift}.  An empty list means the
      database is fully in sync with the registry.

      Emits a [Warn]-level log message for each discrepancy found, so
      calling this during application startup provides an operational
      signal without requiring the caller to inspect the return value.

      Detected drift kinds:
      {ul
      {- {!Pending}: steps in the registry not yet applied to the DB.}
      {- {!Orphaned}: step IDs in the state table absent from the
         registry (migration removed after deploy).}} *)
  val check : Entity.Label.t -> unit -> drift list Lwt.t

  (** Return [(namespace, applied_count, total_count)] for every
      migration registered for [db_label].  Only covers migrations
      present in the current process registry; steps applied by a
      previous deployment that are no longer registered are not
      included. *)
  val status : Entity.Label.t -> unit -> (Namespace.t * int * int) list Lwt.t

  (** [(namespace, pending_step_count)] for every migration that has at
      least one unapplied step. *)
  val pending : Entity.Label.t -> unit -> (Namespace.t * int) list Lwt.t
end

(* ------------------------------------------------------------------ *)
(* Functor                                                             *)
(* ------------------------------------------------------------------ *)

(** Instantiate a migration runner backed by [Db].

    {[
      module Db = Vena.Pools.Make (MyCfg)
      module M  = Vena.Migration.Make (Db)
    ]}
*)
module Make : functor (_ : Pools_sig.Sig) -> RunnerSig

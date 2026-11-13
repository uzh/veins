(** Standalone migration module.

    Types and the global registry live at the top level.  Apply {!Make} to a
    pool module (the output of {!Pools.Make}) to get a runner with
    {!RunnerSig.run_all}, {!RunnerSig.up}, {!RunnerSig.down},
    {!RunnerSig.check}, {!RunnerSig.status}, and {!RunnerSig.pending}.

    {b Design principles}
    - Steps are tracked individually by UUID, not by a per-namespace
      version counter.  An already-applied step is always skipped,
      regardless of its position in the list.
    - Migrations are applied in ascending [written_at] order when calling
      {!RunnerSig.run_all}, so the apply order is deterministic regardless
      of the order modules call {!register}.
    - Steps within a migration are applied in list order (always append new
      steps at the end).
    - Migrations can target different databases.  Use [~for_databases] to
      associate a migration with specific {!Veins.Label.t} values.  Omitting the
      argument defaults to [Database (Label.create "root")].
    - Down migrations are optional.  A step whose [~down] is absent is
      irreversible; {!RunnerSig.down} will log a warning and skip it.

    {b Quick-start}
    {[
    module Db = Veins.Pools.Make (MyCfg)
    module M = Veins.Migration.Make (Db)

    let () =
      let open Veins.Migration in
      register
        ~for_databases:(Database (Veins.Label.create "root"))
        (create
           (Namespace.create "my_app")
           ~written_at:(ptime_of_string "2024-01-15T10:00:00Z")
         |> add_step
              (Step.create
                 ~id:(Id.create "550e8400-e29b-41d4-a716-446655440001")
                 ~label:"create users table"
                 ~down:"DROP TABLE IF EXISTS users"
                 {|CREATE TABLE users (
                       id   INT          PRIMARY KEY AUTO_INCREMENT,
                       name VARCHAR(255) NOT NULL
                     )|})
        )
    ;;

    let () =
      Db.Pool.initialize ();
      Lwt_main.run
        (let%lwt drifts = M.check (Veins.Label.create "root") () in
         (* drifts is [] when the DB is fully up to date *)
         match%lwt M.run_all (Veins.Label.create "root") () with
         | Ok () -> Lwt.return_unit
         | Error e -> invalid_arg (Veins.Error.show e))
    ;;
    ]}

    @canonical Veins.Migration *)

(** Parse an RFC 3339 string into [Ptime.t].  Raises [Invalid_argument] if
    the string is malformed.  Use for static authoring timestamps:
    [ptime_of_string "2024-01-15T10:00:00Z"]. *)
val ptime_of_string : string -> Ptime.t

(** Opaque type for a step's stable identifier (UUID string). *)
module Id : sig
  type t

  val create : string -> t

  (** [derive ~namespace ~index] is a stable UUID (v5) for the step at
      0-based position [index] of [namespace]. Use it for migrations written
      without step ids, e.g. when importing the state of a counter-based
      migration table: the same namespace and position always give the same
      id. *)
  val derive : namespace:string -> index:int -> string

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

(** A single, individually-trackable migration step. *)
module Step : sig
  type t =
    { id : Id.t
      (** Stable UUID — must be globally unique across the entire
          application.  Used as the primary key in the migration-state
          table.  Choose a real UUID v4 at authoring time and never
          change it once the step has been deployed. *)
    ; label : string (** Human-readable description (used in log output). *)
    ; up : string (** SQL statement to apply this step (forward migration). *)
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

  (** Build a step.

      @param id Stable UUID v4 wrapped in {!Id.t}.
      @param label Human-readable description for log output.
      @param check_fk
        Defaults to [true]. Pass [false] to disable FK
        checks around this step on dialects that support it
        (MariaDB / MySQL only).
      @param down Optional SQL to revert the step.
      @param up (positional) SQL to apply the step. *)
  val create : id:Id.t -> label:string -> ?check_fk:bool -> ?down:string -> string -> t

  (** Return the step's stable identifier. *)
  val id : t -> Id.t
end

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
  ; steps : Step.t list
    (** Steps in timeline / dependency order.  Always {b append} new
        steps at the end — never re-order or remove already-deployed
        steps. *)
  }

(** Create a migration without steps. Add steps with {!add_step}.
    @param written_at
      Authoring timestamp.  Use {!ptime_of_string} for
      static literals, e.g.
      [ptime_of_string "2024-01-15T10:00:00Z"]. *)
val create : Namespace.t -> written_at:Ptime.t -> t

(** Append [step] to the end of [migration.steps]. *)
val add_step : Step.t -> t -> t

(** Return the [Id.t] of every step in [migration], in list order. *)
val step_ids : t -> Id.t list

(** Specifies which database(s) a migration should be applied to.

    - [Database label] — exactly one database identified by [label].
    - [Databases labels] — every database whose label appears in [labels].
    - [All] — every database in the pool, regardless of label.
    - [AllExcept labels] — every database {i except} those in [labels]. *)
type database_target =
  | Database of Entity.Label.t
  | Databases of Entity.Label.t list
  | All
  | AllExcept of Entity.Label.t list

(** [target_applies_to target label] returns [true] when [target] covers
    [label]. *)
val target_applies_to : database_target -> Entity.Label.t -> bool

(** Register [migration] so it will be applied when
    {!RunnerSig.run_all} is next called for a matching label.

    [register] is a pure synchronous operation and can be called at
    module initialisation time or from inside an [Lwt.t] callback.
    To target databases whose labels are only known at runtime (e.g.
    fetched via a query), call [register] inside the Lwt sequence
    before invoking the runner:

    {[
    let%lwt labels = Db.collect root fetch_tenant_labels () in
    Migration.register ~for_databases:(Migration.Databases labels) my_migration;
    M.run_all root ()
    ]}

    @param for_databases Which database(s) this migration targets.
                         Defaults to [All]. *)
val register : ?for_databases:database_target -> t -> unit

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

(** Interface satisfied by the output of {!Make}.

    Every function runs on one connection held for the whole call, as
    [?role] (default {!Entity.Role.owner}, i.e. the database's own URL).
    Migration statements declare no needs: the login's grants are what
    limits them. Each step runs in a
    transaction together with its state row (PostgreSQL rolls back both on
    failure; MariaDB commits DDL implicitly). *)
module type RunnerSig = sig
  (** Apply all unapplied steps for every migration registered for
      [db_label], oldest [written_at] first. Returns [Error _] on the first
      failure, leaving the remaining migrations unattempted. *)
  val run_all
    :  ?role:_ Entity.Role.t
    -> Entity.Label.t
    -> unit
    -> (unit, Error.t) Lwt_result.t

  (** Apply the unapplied steps of [migration] to [db_label]. *)
  val up : ?role:_ Entity.Role.t -> Entity.Label.t -> t -> (unit, Error.t) Lwt_result.t

  (** Revert the applied steps of [migration] in reverse order. Steps without
      [down] are logged and skipped. *)
  val down : ?role:_ Entity.Role.t -> Entity.Label.t -> t -> (unit, Error.t) Lwt_result.t

  (** Compare the registry with the state table and return every {!drift}
      ([[]] when in sync). Also logs each one as a warning. *)
  val check : ?role:_ Entity.Role.t -> Entity.Label.t -> unit -> drift list Lwt.t

  (** [(namespace, applied_count, total_count)] for every migration
      registered for [db_label]. *)
  val status
    :  ?role:_ Entity.Role.t
    -> Entity.Label.t
    -> unit
    -> (Namespace.t * int * int) list Lwt.t

  (** [(namespace, pending_step_count)] for every migration with unapplied
      steps. *)
  val pending
    :  ?role:_ Entity.Role.t
    -> Entity.Label.t
    -> unit
    -> (Namespace.t * int) list Lwt.t
end

(** Instantiate a migration runner backed by [Db].

    {[
    module Db = Veins.Pools.Make (MyCfg)
    module M = Veins.Migration.Make (Db)
    ]} *)
module Make : functor (_ : Pools_sig.Sig) -> RunnerSig

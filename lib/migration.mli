(** Migrations.

    An application registers its migrations, into the default set
    ({!register}) or into typed sets ({!Sets.Make}), and calls one function
    to migrate and one to check at startup ({!App_sig}). Veins handles the
    order, running each step, failures, out-of-order migrations, the startup
    check, a read-only dry run for CI and the reports.

    {b Design principles}
    - {b Roll-forward only.} There are no downs and no rollbacks: a mistake
      is fixed by a new migration. Migrations keep the previous release
      working (expand, then contract in a later release), because an older
      release deployed in an emergency runs against the newer schema.
    - Steps are tracked individually by UUID, in the state table
      ({!state_table}), one row per step with its {!Row_status.t}.
    - [written_at] is the one timeline: migrations run in its order, ties by
      namespace ({!order}). A migration that depends on another is written
      after it. Steps within a migration run in list order (always append new
      steps at the end).
    - {b Each step runs on its own}: a step that succeeded stays applied; a
      failure is recorded ([failed], with [last_error]) and stops the run.
      A failed step blocks further runs until an admin repairs the database
      by hand ({!Repair}). Write one statement per step where possible: on
      MariaDB a step with several DDL statements can be left half applied;
      on PostgreSQL the step's transaction reverts it.
    - Every statement says which dialects it is written for ({!Sql}).

    {b Quick-start}
    {[
    module Db = Veins.Pools.Make (MyCfg)
    module Migrations = Veins.Migration.App.Make (Db)

    let () =
      let open Veins.Migration in
      register
        (create
           (Namespace.create "202401151000_users")
           ~written_at:(ptime_of_string "2024-01-15T10:00:00Z")
         |> add_step
              (Step.create
                 ~label:"create users table"
                 (Sql.v
                    ~mariadb:
                      {|CREATE TABLE users (
                          id   INT          PRIMARY KEY AUTO_INCREMENT,
                          name VARCHAR(255) NOT NULL
                        )|}
                    ~postgresql:
                      {|CREATE TABLE users (
                          id   INT          GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
                          name VARCHAR(255) NOT NULL
                        )|}
                    ())))
    ;;

    (* the application's migrate command; at startup:
       Migrations.ensure_clean [ root ] *)
    let migrate args = Migrations.command_exit [ root ] args
    ]}

    @canonical Veins.Migration *)

(** Parse an RFC 3339 string into [Ptime.t].  Raises [Invalid_argument] if
    the string is malformed.  Use for static authoring timestamps:
    [ptime_of_string "2024-01-15T10:00:00Z"]. *)
val ptime_of_string : string -> Ptime.t

(** Opaque type for a step's stable identifier (UUID string). *)
module Id : sig
  type t

  (** A UUID, in any case, stored as its lowercase dashed form.

      Raises [Invalid_argument] if the string is not a UUID. *)
  val create : string -> t

  (** [derive ~namespace ~index] is a stable UUID (v5) for the step at
      0-based position [index] of [namespace]: the same namespace and
      position always give the same id, on every database.

      Raises [Invalid_argument] for a negative [index]. *)
  val derive : namespace:string -> index:int -> t

  val value : t -> string
  val equal : t -> t -> bool
  val pp : Format.formatter -> t -> unit
  val show : t -> string
end

(** Opaque type for a migration's name. *)
module Namespace : sig
  type t

  val create : string -> t
  val value : t -> string
  val equal : t -> t -> bool
  val compare : t -> t -> int
  val pp : Format.formatter -> t -> unit
  val show : t -> string
end

(** The SQL of a step, per dialect. A step applies only to a database whose
    dialect it has SQL for: {!App_sig.migrate} checks every pending step
    before it applies any. *)
module Sql : sig
  type t

  (** [any sql] runs [sql] on every dialect. Say so only for SQL that does. *)
  val any : string -> t

  (** [only kind sql] runs [sql] on [kind] and has nothing for the others. *)
  val only : Dialect.kind -> string -> t

  (** One statement per dialect; a dialect left out is unsupported.

      Raises [Invalid_argument] when both are left out. *)
  val v : ?mariadb:string -> ?postgresql:string -> unit -> t

  (** The SQL for [kind], if any. *)
  val for_kind : t -> Dialect.kind -> string option

  (** The dialects there is SQL for. *)
  val kinds : t -> Dialect.kind list

  (** [is_placeholder sql] holds for SQL that starts with [TODO:] (after
      blanks), the placeholder [veins-gen] writes. Nothing else is, not even
      empty SQL or a comment: veins sends those as they are. *)
  val is_placeholder : string -> bool

  (** [written t kind]: [t] has SQL for [kind] that is not a placeholder
      ({!is_placeholder}). {!App_sig.migrate} applies a step only when it is. *)
  val written : t -> Dialect.kind -> bool
end

(** A single, individually-trackable migration step. *)
module Step : sig
  type t =
    { id : Id.t option
      (** Stable id, the [uuid] in the migration-state table; it must be
          unique across the application and never change once deployed.
          [None] takes {!Id.derive} of the migration's namespace and the
          step's position, so steps must then only ever be appended. *)
    ; label : string (** Human-readable description (used in log output). *)
    ; up : Sql.t (** SQL to apply this step. *)
    ; check_fk : bool
      (** When [false] veins temporarily disables FK checks before
          executing [up].  Has no effect where {!Dialect.set_fk_checks} is
          [None] (PostgreSQL). *)
    }

  (** Build a step.

      @param id Stable id; derived from the position when left out.
      @param label Human-readable description for log output.
      @param check_fk
        Defaults to [true]. Pass [false] to disable FK
        checks around this step on dialects that support it
        (MariaDB / MySQL only).
      @param up (positional) SQL to apply the step. *)
  val create : ?id:Id.t -> label:string -> ?check_fk:bool -> Sql.t -> t

  (** The step's id, if it was given one. *)
  val id : t -> Id.t option
end

(** A named, ordered group of migration steps. *)
type t =
  { namespace : Namespace.t
    (** Unique name of this migration within its set, e.g.
        [Namespace.create "202401151000_users"]. Stored in the state table's
        [namespace] column. *)
  ; written_at : Ptime.t
    (** Authoring timestamp: migrations run in [written_at] order
        ({!order}). Moving it doesn't change the step ids, which derive from
        the namespace. *)
  ; steps : Step.t list
    (** Steps in timeline / dependency order.  Always {b append} new
        steps at the end — never re-order or remove already-deployed
        steps. *)
  }

(** [t], for the modules below that have a [t] of their own. *)
type migration = t

(** Create a migration without steps. Add steps with {!add_step}.

    @param written_at
      Authoring timestamp.  Use {!ptime_of_string} for
      static literals, e.g.
      [ptime_of_string "2024-01-15T10:00:00Z"]. *)
val create : Namespace.t -> written_at:Ptime.t -> t

(** Append [step] to the end of [migration.steps]. *)
val add_step : Step.t -> t -> t

(** Return the id of every step in [migration], in list order: the given
    one, or the one derived from its position. *)
val step_ids : t -> Id.t list

(** [order migrations] is the order the migrations of a set run in:
    [written_at], ties by namespace. *)
val order : t list -> t list

(** {1 Registration} *)

(** Register [migration] into the {b default set}, the one {!App.Make} runs:
    for applications with one kind of database. Use {!Sets.Make} for
    several.

    [register] is a pure synchronous operation and can be called at module
    initialisation time or later; a set is read when it is used.

    {b Linking.} A migration registered at module initialisation in a library
    runs only when the module is linked: a module that nothing references is
    dropped from an executable. Link the migrations' library with
    [(library_flags (-linkall))], or reference every migration module.

    Raises [Invalid_argument] if a migration of the same namespace is in the
    default set already. *)
val register : t -> unit

(** {1 State} *)

(** The name of the migration state table: [veins_migration_state], or
    [VEINS_MIGRATION_TABLE]. For code that treats it specially, e.g. emptying
    every table but this one.

    One row per step that ran or was imported ({!Row.t}). Veins upgrades the
    table itself, under the migration lock, whenever it migrates; the
    upgrade to the current layout (numeric [id], [uuid], [status],
    [last_error], [run_at]) is one-way: a release on an older veins version
    can't read the table any more.

    Raises [Invalid_argument] if [VEINS_MIGRATION_TABLE] is not a plain table name. *)
val state_table : unit -> string

(** A step's state in its row. A step without a row is pending. *)
module Row_status : sig
  type t =
    | Applied
    | Failed (** Blocks the set's runs until repaired by hand ({!Repair}). *)

  val to_string : t -> string

  (** [Error _] for anything but ["applied"] and ["failed"]: reading such a
      row is a decode error. *)
  val of_string : string -> (t, string) result

  val equal : t -> t -> bool
  val pp : Format.formatter -> t -> unit
end

(** A row of the state table. *)
module Row : sig
  type t =
    { id : int option (** The row's id; [None] before the table's upgrade. *)
    ; uuid : Id.t (** The step's id: what reports and repairs use. *)
    ; namespace : Namespace.t
    ; label : string
    ; status : Row_status.t
    ; last_error : string option
      (** The most recent failure; stays after the step was marked applied. *)
    ; run_at : Ptime.t option
      (** When the step last ran (or the row was written, for imported rows). *)
    }
end

(** The statements an admin runs to repair a failed step, by its UUID, for
    the state table of {!state_table}:

    - completed the step by hand: {!Repair.mark_applied}; the next run continues
      after it ([last_error] stays, as a record);
    - undid what the step left behind: {!Repair.delete}; the next run runs it
      again. *)
module Repair : sig
  val mark_applied : Dialect.kind -> Id.t -> string
  val delete : Dialect.kind -> Id.t -> string
end

(** {1 Applications} *)

(** A pending migration that comes before a migration applied already, in
    the set's order: what happens when an older branch is merged after a
    newer migration was deployed. A migration with a step appended after a
    later migration was applied is one too. *)
module Out_of_order : sig
  type t =
    { namespace : Namespace.t
    ; newest_applied : Namespace.t (** The last applied migration of the set. *)
    }
end

(** What {!App_sig.migrate} does with out-of-order migrations: [`Fail]
    refuses to run unless each one is allowed by name
    ([~allow_out_of_order]), [`Warn] logs and runs them. *)
type out_of_order_policy =
  [ `Warn
  | `Fail
  ]

(** A database's migration state, judged against the set of the running
    release. *)
module Report : sig
  type t =
    { label : Entity.Label.t
    ; set : string (** The set's name. *)
    ; dialect : Dialect.kind
    ; pending : (Namespace.t * string list) list
      (** The pending steps' labels per migration, in the order they'd run. *)
    ; out_of_order : Out_of_order.t list (** Under either policy. *)
    ; failed : Row.t list (** Failed steps of the set: block the runs. *)
    ; orphaned : Row.t list
      (** Rows outside the set, e.g. after an older release was deployed:
          reported, never acted on, failed ones included. *)
    ; unsupported : (Namespace.t * string list) list
      (** Pending steps without SQL for the dialect (their labels), by
          migration. *)
    ; uninitialized : bool
      (** No state table, but other tables: import the previous engine's
          state first ({!Import}, which creates the state table, also when
          it has nothing to import). *)
    }

  (** The number of pending steps per migration, in the order they'd run. *)
  val pending_counts : t -> (Namespace.t * int) list

  (** The number of pending steps. *)
  val pending_total : t -> int

  (** Several lines; failed steps with the repair statements ({!Repair}). *)
  val pp : Format.formatter -> t -> unit

  val show : t -> string
end

(** Why {!App_sig.migrate} refuses to run. *)
module Refusal : sig
  (** The first in [migrate]'s order. *)
  type t =
    | Duplicates of string (** A namespace or step id is in the set twice. *)
    | Missing_dialect of (Namespace.t * string list) list
    (** Pending steps without SQL for the dialect (their labels), by
        migration. *)
    | Uninitialized
    (** No state table, but other tables: import the previous engine's
        state first ({!Import}, which creates the state table, also when
        it has nothing to import). *)
    | Failed of Row.t list
    (** Failed steps of the set: repair them by hand ({!Repair}). *)
    | Out_of_order of Out_of_order.t list
    (** Only under [`Fail]: the out-of-order migrations not allowed. *)

  (** What to do, with the repair statements for [dialect]; several lines. *)
  val pp : dialect:Dialect.kind -> Format.formatter -> t -> unit

  val show : dialect:Dialect.kind -> t -> string

  (** One line. *)
  val summary : t -> string
end

(** Would {!App_sig.migrate} run, and what would it do? *)
module Dry_run : sig
  type t =
    { report : Report.t
    ; allowed : Out_of_order.t list
      (** Out-of-order migrations that would run: allowed by name, or all
          under [`Warn]. *)
    ; refusal : Refusal.t option (** [None]: [migrate] would run. *)
    }

  (** [of_state ~label ~set ~out_of_order ~dialect ~state_table ~other_tables ~rows migrations]
      decides as [migrate] does, from whether the state table exists
      ([state_table]), its [rows] and whether the database has
      [other_tables]. *)
  val of_state
    :  ?allow_out_of_order:Namespace.t list
    -> label:Entity.Label.t
    -> set:string
    -> out_of_order:out_of_order_policy
    -> dialect:Dialect.kind
    -> state_table:bool
    -> other_tables:bool
    -> rows:Row.t list
    -> migration list
    -> t

  val pp : Format.formatter -> t -> unit
  val show : t -> string
end

(** A database's state for the startup check: what {!App_sig.migrate} would
    do with it, without any out-of-order allowance. *)
module Status : sig
  type t =
    | Ready
    (** Nothing pending, nothing refused. Orphaned rows and out-of-order
        migrations under [`Warn] don't count. *)
    | Pending of Report.t (** [migrate] runs the pending steps. *)
    | Blocked of Refusal.t * Report.t (** [migrate] refuses: a person has to act first. *)

  val of_dry_run : Dry_run.t -> t
  val is_ready : t -> bool

  (** One line. *)
  val pp : Format.formatter -> t -> unit

  val show : t -> string
end

(** Importing the state of another migration engine, once per database.
    Run it with [Import.run] of an application ({!App_sig}), from a command
    of the application's own: it needs the application's migrations. *)
module Import : sig
  (** One migration of the other engine. *)
  type entry =
    { namespace : Namespace.t
    ; applied : int (** The first [applied] steps are applied. *)
    ; failed : string option
      (** Step [applied + 1] failed, with this message (a dirty flag). *)
    }

  (** Where the entries come from. *)
  module type Source = sig
    (** Prefixes [last_error] of the failed rows. *)
    val name : string

    (** Reads the entries, without writing, on the connection the import
        runs on (the migration lock held). *)
    val read : Caqti_lwt.connection -> (entry list, Caqti.Error.t) Lwt_result.t
  end

  (** A counter table (namespace, version, dirty) like Sihl's,
      [core_migration_state] by default. A missing table has no entries; a
      dirty namespace becomes a [failed] row.

      Raises [Invalid_argument] if [table] is not a plain table name. *)
  val counter_state : ?table:string -> unit -> (module Source)

  module Report : sig
    type t =
      { applied : (Namespace.t * int) list (** Steps imported as applied. *)
      ; failed : (Namespace.t * string) list (** Steps imported as failed. *)
      ; unknown : Namespace.t list (** Not in the set: skipped. *)
      ; too_large : (Namespace.t * int * int) list
        (** Counters larger than the migration's step count (counter,
            steps). *)
      }

    (** One line, for the deploy log. *)
    val pp : Format.formatter -> t -> unit

    val show : t -> string
  end

  (** [plan ~source migrations ~existing entries]: the rows an import writes
      (with no [id] and no [run_at]) and its report. Steps in [existing] (with
      a row already) are left as they are. *)
  val plan
    :  source:string
    -> migration list
    -> existing:Id.t list
    -> entry list
    -> Report.t * Row.t list
end

(** The arguments of {!App_sig.command}. *)
module Command : sig
  type action =
    | Up of Namespace.t list (** [up], with the namespaces allowed out of order. *)
    | Dry_run of Namespace.t list
    | Status
    | Check

  val usage : string

  (** [[]] and [["up"]] are [Up []]; [--allow-out-of-order] takes one or more
      namespaces and may be repeated, after [up] or [dry-run]. [Error usage]
      for anything else. *)
  val parse : string list -> (action, string) result

  (** The namespaces of [ALLOW_OUT_OF_ORDER]'s value, separated by commas or
      whitespace. *)
  val allowed_of_env : string option -> Namespace.t list

  (** ["ALLOW_OUT_OF_ORDER"]. *)
  val env_variable : string
end

(** Importing another engine's state into a label's set ({!Import}). *)
module type Import_sig = sig
  (** Under the migration lock, after veins' upgrades of its state table:
      writes a row for every step the source counts that has none ([applied],
      or [failed] with [last_error] ["<source>: <message>"]), and never
      changes a row veins has. Never refuses: a failed entry is repaired by
      hand like any failed step. Idempotent. *)
  val run
    :  ?role:_ Entity.Role.t
    -> source:(module Import.Source)
    -> Entity.Label.t
    -> (Import.Report.t, Error.t) Lwt_result.t
end

(** Migrations in an application: {!App.Make} for the default set,
    {!Sets.Make}'s [App] for typed sets. Every function runs as [?role]
    (default {!Veins.Role.owner}). *)
module type App_sig = sig
  (** Runs the label's set:

      + orders the set ({!order});
      + takes the migration lock;
      + refuses on any {!Refusal.t}: steps without SQL for the dialect,
        an uninitialized database, a failed step (named with its UUID,
        [last_error] and the repair statements), or out-of-order migrations
        under [`Fail] not named in [~allow_out_of_order] (under [`Warn], and
        for those named, they're logged and run; a name that isn't out of
        order is ignored with a log line);
      + creates or upgrades the state table;
      + runs the pending steps in order, each on its own, and stops at the
        first failure, which is recorded as a failed row (a lost connection
        is not: the step stays pending).

      Logs the outcome; errors (also an unreachable database) are returned,
      not raised. *)
  val migrate
    :  ?role:_ Entity.Role.t
    -> ?allow_out_of_order:Namespace.t list
    -> Entity.Label.t
    -> (unit, Error.t) Lwt_result.t

  (** What {!migrate} would do with the same arguments, without the lock and
      without writing: works with a read-only login, so CI can point it at a
      production database. *)
  val dry_run
    :  ?role:_ Entity.Role.t
    -> ?allow_out_of_order:Namespace.t list
    -> Entity.Label.t
    -> (Dry_run.t, Error.t) Lwt_result.t

  (** The label's status; only reads. Errors (an unreachable database) are
      returned. *)
  val ready : ?role:_ Entity.Role.t -> Entity.Label.t -> (Status.t, Error.t) Lwt_result.t

  (** The label's report; only reads. Raises what the database raises. Why
      [migrate] would refuse is in {!dry_run} and {!ready}. *)
  val report : ?role:_ Entity.Role.t -> Entity.Label.t -> Report.t Lwt.t

  (** The check at startup for one label, by [?policy]: [`Fail] (default)
      returns any status but [Ready] as an error, [`Warn] logs it, [`Skip]
      reads nothing (tests). Only reads. A state it can't read (an
      unreachable database) is logged; [`Warn] continues, [`Fail] raises
      [Error.Exn] ([Connection_failed] when unreachable). *)
  val check
    :  ?role:_ Entity.Role.t
    -> ?policy:[ `Fail | `Warn | `Skip ]
    -> Entity.Label.t
    -> (unit, Status.t) Lwt_result.t

  (** The startup utility: unless every label is clean ({!Status.Ready}),
      logs each report and raises
      [Error.Exn (Migration_not_clean [ label, status; … ])], so the
      application doesn't start: pending steps, and anything [migrate] would
      refuse ({!Status.Blocked}), out-of-order migrations of a [`Fail] set
      included. Orphaned rows and out-of-order migrations under [`Warn] are
      logged, not raised. A state it can't read raises [Error.Exn]
      ([Connection_failed] when the database is unreachable). [~skip:true]
      reads nothing (tests). Only reads.
      Applications that must keep serving the other databases when one is
      unclean use {!ready} or {!check} per database instead. *)
  val ensure_clean
    :  ?role:_ Entity.Role.t
    -> ?skip:bool
    -> Entity.Label.t list
    -> unit Lwt.t

  (** A migrate command for the application's own command line, given its
      arguments ({!Command.parse}); prints to [?out] (default stdout) and
      returns the exit code, the worst of every label (all run):
      - [[]], [["up"]]: {!migrate}; 1 if any fails
      - [["up"; "--allow-out-of-order"; ns; …]]: the same, allowing [ns]
      - [["dry-run"]] (with the same flags): {!dry_run}; 1 if [migrate]
        would refuse on any label
      - [["status"]]: each label's {!Report.t}; 0
      - [["check"]]: the dry run's output; 1 unless every label is
        {!Status.Ready}
      - anything else: the usage; 2

      [up] and [dry-run] also allow the namespaces of the environment
      variable [ALLOW_OUT_OF_ORDER] ({!Command.allowed_of_env}), so a CI
      variable allows a migration for the preflight and the deploy alike. An
      error that prevents the answer (an unreachable database) is 1. *)
  val command
    :  ?role:_ Entity.Role.t
    -> ?out:Format.formatter
    -> Entity.Label.t list
    -> string list
    -> int Lwt.t

  (** {!command}, then [exit] with its code. *)
  val command_exit
    :  ?role:_ Entity.Role.t
    -> ?out:Format.formatter
    -> Entity.Label.t list
    -> string list
    -> 'a Lwt.t

  module Import : Import_sig
end

(** The default set: the migrations of {!register}, out-of-order [`Fail]. *)
module App : sig
  module Make (_ : Pools_sig.Sig) : App_sig
end

(** Typed sets of migrations, e.g. a root database and tenants:

    {[
    module Sets =
      Veins.Migration.Sets.Make
        (struct
          type t =
            [ `Root
            | `Tenant
            ]

          let all = [ `Root; `Tenant ]

          let name = function
            | `Root -> "root"
            | `Tenant -> "tenant"
          ;;

          let out_of_order = function
            | `Root -> `Fail
            | `Tenant -> `Warn
          ;;
        end)
        (Db)

    module Migrate = Sets.App (struct
        let set_for label = if is_root label then `Root else `Tenant
      end)

    (* in a migration file *)
    let () = Sets.register ~sets:[ `Tenant ] migration
    ]} *)
module Sets : sig
  module type S = sig
    type t

    (** Every set; their names must differ. *)
    val all : t list

    val name : t -> string
    val out_of_order : t -> out_of_order_policy
  end

  (** Raises [Invalid_argument] if two sets have the same name. *)
  module Make (S : S) (_ : Pools_sig.Sig) : sig
    (** Register [migration] into [sets] (required, so a migration can't land
        in every set by accident). As {!Veins.Migration.register}: at module
        initialisation or later, and mind the linker.

        Raises [Invalid_argument] if [sets] is empty, or if a migration of
        the same namespace is in one of [sets] already. The same namespace in
        different sets is fine. *)
    val register : sets:S.t list -> t -> unit

    (** The migrations of [set] in the order they run ({!order}). *)
    val migrations : S.t -> t list

    module App (_ : sig
        val set_for : Entity.Label.t -> S.t
      end) : App_sig
  end
end

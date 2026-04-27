(** SQL dialect abstraction for database-specific DDL differences.

    Provide an implementation of {!Sig} as the [Dialect] field of a
    {!Pools_sig.ConfigSig} to let the migration engine generate correct SQL
    for the target database.

    Two implementations are provided out of the box:
    - {!Mariadb} — for MariaDB / MySQL
    - {!Postgresql} — for PostgreSQL *)

(** The interface a dialect module must satisfy. *)
module type Sig = sig
  (** DDL to create (or ensure the existence of) the migration-state tracking
      table.

      @param table
        Fully-qualified table name, e.g.
        ["vena_migration_state"].  May be overridden at runtime
        via the [VENA_MIGRATION_TABLE] environment variable. *)
  val create_migration_table : table:string -> string

  (** Whether [SET FOREIGN_KEY_CHECKS = 0 / 1] is supported by this
      dialect.  [true] for MariaDB / MySQL; [false] for PostgreSQL.

      When a migration step sets [~check_fk:false] the runner wraps it in
      [SET FOREIGN_KEY_CHECKS = 0 … 1] only if this flag is [true]. *)
  val fk_checks_supported : bool

  (** [SELECT id FROM <table>] — returns every applied step ID. *)
  val select_applied_ids : table:string -> string

  (** [SELECT id, namespace FROM <table>] — returns every applied step with
      its namespace.  Used by the drift-detection ({!Migration.RunnerSig.check}) pass. *)
  val select_applied_rows : table:string -> string

  (** [INSERT INTO <table> (id, namespace, label, created_at, updated_at) VALUES (?, ?, ?, ?, ?)]
      — records a newly-applied step.  Placeholders: id, namespace, label, created_at, updated_at.
  *)
  val insert_applied_step : table:string -> string

  (** [DELETE FROM <table> WHERE id = ?] — removes a step record during a
      down migration. *)
  val delete_applied_step : table:string -> string
end

(** MariaDB / MySQL dialect.

    Table engine: [InnoDB], character set: [utf8mb4], collation:
    [utf8mb4_unicode_ci].  FK-check suppression is supported. *)
module Mariadb : Sig

(** PostgreSQL dialect.

    Standard [CREATE TABLE].  FK-check suppression is {b not} supported
    ([fk_checks_supported = false]). *)
module Postgresql : Sig

(** Infer the dialect from a connection URL's scheme.

    Returns [Some (module Mariadb)] for [mariadb://] or [mysql://] URLs,
    [Some (module Postgresql)] for [postgresql://] or [postgres://] URLs, and
    [None] for unrecognised schemes.

    Useful for validating that a registered database URL matches the
    dialect the pool was configured with. *)
val of_url : Entity.Url.t -> (module Sig) option

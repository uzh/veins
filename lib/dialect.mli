(** SQL dialect abstraction for database-specific DDL differences.

    Provide an implementation of {!Sig} as the [Dialect] field of a
    {!Pools_sig.ConfigSig} to let the migration engine generate correct SQL
    for the target database.

    Two implementations are provided out of the box:
    - {!Mariadb} — for MariaDB / MySQL
    - {!Postgresql} — for PostgreSQL

    @canonical Veins.Dialect *)

(** The interface a dialect module must satisfy. *)
module type Sig = sig
  (** Statements run on every new connection, before it is used. Both
      dialects pin the session to UTC here, so [NOW()] / [CURRENT_TIMESTAMP]
      agree with the UTC values caqti writes for [Ptime.t], whatever the
      server's time zone. *)
  val session_setup : string list

  (** [true] when the error means the connection is gone, so the pool must be
      dropped and reconnected. Any other error (a constraint violation, a
      syntax error, …) leaves the pool alone.

      The implementations here only know connect and load errors; the driver
      packages ([Veins_mariadb.Dialect], [Veins_postgresql.Dialect]) also
      recognise the driver's own "connection lost" errors. *)
  val is_connection_error : Caqti.Error.t -> bool

  (** [true] when the database refused a statement for lack of privileges;
      veins then raises [Error.Permission_denied]. Like
      {!is_connection_error}, only the driver packages' dialects recognise
      these errors; the implementations here always answer [false]. *)
  val is_permission_error : Caqti.Error.t -> bool

  (** Statements run on a connection after rolling back a transaction, before
      it is used again. MariaDB restores [autocommit]: caqti-driver-mariadb
      (3.1) turns it off to start a transaction and back on when committing,
      but not when rolling back, so the next statements on that pooled
      connection would run in a transaction that is never committed. *)
  val after_rollback : string list

  (** DDL to create (or ensure the existence of) the migration-state tracking
      table.

      @param table
        Fully-qualified table name, e.g.
        ["veins_migration_state"].  May be overridden at runtime
        via the [VEINS_MIGRATION_TABLE] environment variable. *)
  val create_migration_table : table:string -> string

  (** Whether [SET FOREIGN_KEY_CHECKS = 0 / 1] is supported by this
      dialect.  [true] for MariaDB / MySQL; [false] for PostgreSQL.

      When a migration step sets [~check_fk:false] the runner wraps it in
      [SET FOREIGN_KEY_CHECKS = 0 … 1] only if this flag is [true]. *)
  val fk_checks_supported : bool

  (** [SELECT id FROM <table>] — returns every applied step ID. *)
  val select_applied_ids : table:string -> string

  (** [SELECT id, namespace FROM <table>] — returns every applied step with
      its namespace.  Used by the drift-detection ([Migration.RunnerSig.check]) pass. *)
  val select_applied_rows : table:string -> string

  (** [INSERT INTO <table> (id, namespace, label, created_at, updated_at) VALUES (?, ?, ?, ?, ?)]
      — records a newly-applied step.  Placeholders: id, namespace, label, created_at, updated_at.
  *)
  val insert_applied_step : table:string -> string

  (** [DELETE FROM <table> WHERE id = ?] — removes a step record during a
      down migration. *)
  val delete_applied_step : table:string -> string

  (** [INSERT INTO <table> (<col1>, ...) VALUES (?, ...)] — generic single-row
      insert with one [?] placeholder per column.  Used by
      [Pools_sig.Sig.populate]. *)
  val insert_row : table:string -> columns:string list -> string

  (** Wrap a column name for use in a [SELECT] to return a UUID stored in
      the dialect's native format as a lowercase dashed string.

      - MariaDB ([BINARY(16)]): [LOWER(CONCAT(SUBSTR(HEX(<field>),1,8),'-',...))]
      - PostgreSQL ([UUID]):    [<field>::text] *)
  val uuid_select_fragment : field:string -> string

  (** Wrap a [?] placeholder for use in an [INSERT] or [WHERE] clause
      when the target column stores UUIDs in the dialect's native format.

      - MariaDB ([BINARY(16)]): [UNHEX(REPLACE(<name>,'-',''))]
      - PostgreSQL ([UUID]):    [<name>::uuid] *)
  val uuid_value_fragment : string -> string
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

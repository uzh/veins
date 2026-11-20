(** SQL that differs between database systems.

    Caqti tells every connection's dialect ([Caqti.Template.Dialect.t]), and a
    Caqti 3 request may render its SQL from it. Veins builds its own requests
    that way ({!request}), so one pool works on MariaDB and PostgreSQL alike,
    without configuring a dialect. The functions here are the SQL veins needs,
    by {!type-kind}; applications may use them to build their own dialect-dependent
    requests, or with a fixed kind where the database is known (e.g. a
    package for MariaDB only).

    PostgreSQL gets PostgreSQL's SQL, everything else MariaDB's: Caqti also
    renders requests for logging, with a dialect that names no database, so
    none of these may fail.

    @canonical Veins.Dialect *)

type t = Caqti.Template.Dialect.t

type kind =
  | Mariadb (** MariaDB or MySQL; also every dialect other than PostgreSQL. *)
  | Postgresql

val kind : t -> kind

(** [request policy request_type sql] is a request rendering [sql kind] for
    the dialect of the connection it runs on, e.g.
    {[
    Dialect.request
      Caqti.Template.Request.Static
      Caqti.Templater.T.(string -->. unit)
      (fun dialect ->
         Format.asprintf
           "DELETE FROM t WHERE id = %s"
           (Dialect.uuid_value_fragment dialect "?"))
    ]}
    The string is parsed like [Caqti.Templater.static]'s ([?] parameters). *)
val request
  :  Caqti.Template.Request.prepare_policy
  -> ('a, 'b, 'm) Caqti.Template.Request_type.t
  -> (kind -> string)
  -> ('a, 'b, 'm) Caqti.Template.Request.t

(** {1 Sessions} *)

(** Pins the session's time zone to UTC, so [NOW()] / [CURRENT_TIMESTAMP]
    agree with the UTC values Caqti writes for [Ptime.t], whatever the
    server's time zone. Caqti's MariaDB and PostgreSQL drivers do this on
    every new connection themselves, so veins doesn't send it; it is here for
    sessions that changed their time zone. *)
val set_utc : kind -> string

(** Run on a connection after rolling back a transaction, before it is used
    again. MariaDB restores [autocommit]: caqti-driver-mariadb (3.1) turns it
    off to start a transaction and back on when committing, but not when
    rolling back, so the next statements on that pooled connection would run
    in a transaction that is never committed. [None] for PostgreSQL. *)
val restore_autocommit : kind -> string option

(** [SET FOREIGN_KEY_CHECKS = 0 / 1] on MariaDB; [None] where foreign key
    checks can't be switched off for a session (PostgreSQL). *)
val set_fk_checks : kind -> bool -> string option

(** {1 Identifiers and locks} *)

(** [true] for a plain SQL identifier: letters, digits and [_], not starting
    with a digit, at most 64 characters. The functions here taking a table,
    a field or a name put it into the SQL as it is: check names that don't
    come from the source code, and never pass user input. *)
val is_identifier : string -> bool

(** Counts the tables of the given name in the connection's database (its
    schema search path on PostgreSQL). Parameter: the table name. *)
val table_exists : kind -> string

(** Lists the base tables (no views) of the connection's database (its schema
    search path on PostgreSQL), ordered by name. No parameters; one string
    per row. *)
val list_tables : kind -> string

(** Empties a table. PostgreSQL adds [CASCADE] (tables referencing it are
    emptied too); on MariaDB a table referenced by foreign keys needs the
    checks turned off, see {!Connection.without_fk_checks}. *)
val truncate : kind -> table:string -> string

(** Drops a table if it exists. PostgreSQL adds [CASCADE]. *)
val drop : kind -> table:string -> string

(** Tries to take a lock that the session holds until {!unlock} or until it
    ends, without waiting: selects [1] if it got it, [0] if another session
    holds it. The lock belongs to the connection's database. MariaDB
    [GET_LOCK], PostgreSQL [pg_try_advisory_lock]. Parameter: the lock's
    name. *)
val try_lock : kind -> string

(** Releases a lock taken with {!try_lock}. Parameter: the lock's name. *)
val unlock : kind -> string

(** {1 UUIDs}

    [field] and the expression go into the SQL as they are. *)

(** Wraps a column to return a UUID stored in the dialect's native format as
    a lowercase dashed string.

    - MariaDB ([BINARY(16)]): [LOWER(CONCAT(SUBSTR(HEX(<field>),1,8),'-',...))]
    - PostgreSQL ([UUID]): [<field>::text] *)
val uuid_select_fragment : kind -> field:string -> string

(** Wraps a [?] placeholder (or any expression) for a column storing UUIDs in
    the dialect's native format.

    - MariaDB ([BINARY(16)]): [UNHEX(REPLACE(<name>,'-',''))]
    - PostgreSQL ([UUID]): [<name>::uuid] *)
val uuid_value_fragment : kind -> string -> string

(** {1 Migration state}

    The table is {!Migration.state_table}: [veins_migration_state], or
    [VEINS_MIGRATION_TABLE]. One row per step: a numeric [id] (primary key),
    the step's [uuid] (unique), [namespace], [label], [status] ([applied] or
    [failed]; a MariaDB [ENUM], a PostgreSQL [VARCHAR] with a [CHECK]),
    [last_error], [run_at], [created_at] and [updated_at]. *)

(** Creates the table in its current layout, if there is none. *)
val create_migration_table : kind -> table:string -> string

(** Counts the columns of the given name in a table of the connection's
    database. Parameters: the table name, the column name. *)
val column_exists : kind -> string

(** The name of a table's primary key constraint (no row without one).
    Parameter: the table name. *)
val primary_key_name : kind -> string

(** Upgrades a table of the first layout ([id] the step's UUID and primary
    key, no [status], [last_error], [run_at]) to the current one: [id]
    becomes [uuid], a new numeric [id] the primary key, numbered by
    [created_at] (then [uuid]), every row [applied]. Several statements, in
    one transaction on PostgreSQL; on MariaDB the last one switches the
    layout, and the ones before it can run again. [primary_key] is the name of the table's primary key
    constraint ({!primary_key_name}), used on PostgreSQL only. *)
val upgrade_migration_table : kind -> table:string -> primary_key:string -> string list

(** Every row: id, uuid (dashed), namespace, label, status, last_error and
    [COALESCE(run_at, created_at)], by id. *)
val select_state_rows : kind -> table:string -> string

(** {!select_state_rows} for a table of the first layout, not upgraded yet:
    no id ([NULL]), every row [applied], no error, [created_at]. *)
val select_state_rows_v1 : kind -> table:string -> string

(** Writes a step's row, or updates the one it has (on [uuid]): status,
    last_error, run_at and updated_at are replaced. Parameters: uuid, namespace, label, status, last_error, run_at,
    created_at, updated_at. *)
val upsert_step_row : kind -> table:string -> string

(** {!upsert_step_row} that leaves an existing row as it is. *)
val insert_step_row_if_missing : kind -> table:string -> string

(** [repair_mark_applied kind ~table ~uuid]: the statement an admin runs to
    mark a failed step applied after completing it by hand, with the UUID
    written out ([UNHEX(REPLACE('…', '-', ''))] on MariaDB). *)
val repair_mark_applied : kind -> table:string -> uuid:string -> string

(** [repair_delete kind ~table ~uuid]: the statement an admin runs to remove
    a failed step's row after undoing what it left behind, so the step runs
    again. *)
val repair_delete : kind -> table:string -> uuid:string -> string

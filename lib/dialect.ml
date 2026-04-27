(** SQL dialect abstraction for database-specific DDL differences.

    MariaDB and PostgreSQL differ in:
    - Table creation options (ENGINE=InnoDB, character set)
    - Support for [SET FOREIGN_KEY_CHECKS] (MariaDB only)

    Provide a [Dialect.Sig] implementation as part of {!Pools_sig.ConfigSig}. *)

module type Sig = sig
  (** DDL for the migration-state tracking table.
      @param table fully-qualified table name, e.g. ["vena_migration_state"] *)
  val create_migration_table : table:string -> string

  (** Whether [SET FOREIGN_KEY_CHECKS = 0/1] is supported.
      [true] for MariaDB/MySQL, [false] for PostgreSQL. *)
  val fk_checks_supported : bool

  (** SELECT all applied step IDs. *)
  val select_applied_ids : table:string -> string

  (** SELECT applied step IDs with their namespace (used for drift detection). *)
  val select_applied_rows : table:string -> string

  (** INSERT a newly-applied step record.
      Placeholders: [(id, namespace, label, created_at, updated_at)]. *)
  val insert_applied_step : table:string -> string

  (** DELETE a step record by id. *)
  val delete_applied_step : table:string -> string
end

(** MariaDB / MySQL dialect. *)
module Mariadb : Sig = struct
  let create_migration_table ~table =
    Printf.sprintf
      {|CREATE TABLE IF NOT EXISTS %s (
          id          VARCHAR(36)  NOT NULL,
          namespace   VARCHAR(128) NOT NULL,
          label       VARCHAR(256) NOT NULL,
          created_at  DATETIME(3)  NOT NULL,
          updated_at  DATETIME(3)  NOT NULL,
          PRIMARY KEY (id)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci|}
      table
  ;;

  let fk_checks_supported = true
  let select_applied_ids ~table = Printf.sprintf "SELECT id FROM %s" table
  let select_applied_rows ~table = Printf.sprintf "SELECT id, namespace FROM %s" table

  let insert_applied_step ~table =
    Printf.sprintf
      "INSERT INTO %s (id, namespace, label, created_at, updated_at) VALUES (?, ?, ?, ?, \
       ?)"
      table
  ;;

  let delete_applied_step ~table = Printf.sprintf "DELETE FROM %s WHERE id = ?" table
end

(** PostgreSQL dialect. *)
module Postgresql : Sig = struct
  let create_migration_table ~table =
    Printf.sprintf
      {|CREATE TABLE IF NOT EXISTS %s (
          id          VARCHAR(36)  NOT NULL,
          namespace   VARCHAR(128) NOT NULL,
          label       VARCHAR(256) NOT NULL,
          created_at  TIMESTAMP    NOT NULL,
          updated_at  TIMESTAMP    NOT NULL,
          PRIMARY KEY (id)
        )|}
      table
  ;;

  let fk_checks_supported = false
  let select_applied_ids ~table = Printf.sprintf "SELECT id FROM %s" table
  let select_applied_rows ~table = Printf.sprintf "SELECT id, namespace FROM %s" table

  let insert_applied_step ~table =
    Printf.sprintf
      "INSERT INTO %s (id, namespace, label, created_at, updated_at) VALUES (?, ?, ?, ?, \
       ?)"
      table
  ;;

  let delete_applied_step ~table = Printf.sprintf "DELETE FROM %s WHERE id = ?" table
end

(** Infer the dialect from a connection URL's scheme.

    Returns [Some (module Mariadb)] for [mariadb://] or [mysql://] URLs,
    [Some (module Postgresql)] for [postgresql://] or [postgres://] URLs, and
    [None] for unrecognised schemes. *)
let of_url url =
  match Uri.scheme (Entity.Url.to_uri url) with
  | Some ("mariadb" | "mysql") -> Some (module Mariadb : Sig)
  | Some ("postgresql" | "postgres") -> Some (module Postgresql : Sig)
  | _ -> None
;;

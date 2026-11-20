type t = Caqti.Template.Dialect.t

type kind =
  | Mariadb
  | Postgresql

let kind : t -> kind = function
  | Caqti.Template.Dialect.Pgsql _ -> Postgresql
  | _ -> Mariadb
;;

let set_utc dialect =
  match dialect with
  | Mariadb -> "SET time_zone = '+00:00'"
  | Postgresql -> "SET TIME ZONE 'UTC'"
;;

let restore_autocommit dialect =
  match dialect with
  | Mariadb -> Some "SET autocommit = 1"
  | Postgresql -> None
;;

let set_fk_checks dialect enabled =
  match dialect with
  | Mariadb ->
    Some (Format.asprintf "SET FOREIGN_KEY_CHECKS = %d" (CCBool.to_int enabled))
  | Postgresql -> None
;;

let uuid_select_fragment dialect ~field =
  match dialect with
  | Mariadb ->
    Format.asprintf
      "LOWER(CONCAT(SUBSTR(HEX(%s),1,8),'-',SUBSTR(HEX(%s),9,4),'-',SUBSTR(HEX(%s),13,4),'-',SUBSTR(HEX(%s),17,4),'-',SUBSTR(HEX(%s),21)))"
      field
      field
      field
      field
      field
  | Postgresql -> Format.asprintf "%s::text" field
;;

let uuid_value_fragment dialect name =
  match dialect with
  | Mariadb -> Format.asprintf "UNHEX(REPLACE(%s,'-',''))" name
  | Postgresql -> Format.asprintf "%s::uuid" name
;;

let is_identifier name =
  let length = CCString.length name in
  length > 0
  && length <= 64
  && CCString.for_all
       (function
         | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' -> true
         | _ -> false)
       name
  &&
  match CCString.get name 0 with
  | '0' .. '9' -> false
  | _ -> true
;;

let table_exists dialect =
  match dialect with
  | Mariadb ->
    "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE() AND \
     table_name = ?"
  | Postgresql ->
    "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = ANY \
     (current_schemas(false)) AND table_name = LOWER(?)"
;;

let list_tables dialect =
  match dialect with
  | Mariadb ->
    "SELECT table_name FROM information_schema.tables WHERE table_schema = DATABASE() \
     AND table_type = 'BASE TABLE' ORDER BY table_name"
  | Postgresql ->
    "SELECT table_name FROM information_schema.tables WHERE table_schema = ANY \
     (current_schemas(false)) AND table_type = 'BASE TABLE' ORDER BY table_name"
;;

let truncate dialect ~table =
  match dialect with
  | Mariadb -> Format.asprintf "TRUNCATE TABLE %s" table
  | Postgresql -> Format.asprintf "TRUNCATE TABLE %s CASCADE" table
;;

let drop dialect ~table =
  match dialect with
  | Mariadb -> Format.asprintf "DROP TABLE IF EXISTS %s" table
  | Postgresql -> Format.asprintf "DROP TABLE IF EXISTS %s CASCADE" table
;;

(* MariaDB's lock names are global to the server and at most 64 characters:
   hash the name together with the database. PostgreSQL's advisory locks
   belong to the database. *)
let mariadb_lock_name = "CONCAT('veins:', MD5(CONCAT(DATABASE(), ':', ?)))"

let try_lock dialect =
  match dialect with
  | Mariadb -> Format.asprintf "SELECT COALESCE(GET_LOCK(%s, 0), 0)" mariadb_lock_name
  | Postgresql -> "SELECT CASE WHEN pg_try_advisory_lock(hashtext(?)) THEN 1 ELSE 0 END"
;;

let unlock dialect =
  match dialect with
  | Mariadb -> Format.asprintf "SELECT COALESCE(RELEASE_LOCK(%s), 0)" mariadb_lock_name
  | Postgresql -> "SELECT CASE WHEN pg_advisory_unlock(hashtext(?)) THEN 1 ELSE 0 END"
;;

let create_migration_table dialect ~table =
  match dialect with
  | Mariadb ->
    Format.asprintf
      {|CREATE TABLE IF NOT EXISTS %s (
          id          BIGINT       NOT NULL AUTO_INCREMENT,
          uuid        BINARY(16)   NOT NULL,
          namespace   VARCHAR(128) NOT NULL,
          label       VARCHAR(256) NOT NULL,
          status      ENUM('applied','failed') NOT NULL DEFAULT 'applied',
          last_error  TEXT         NULL,
          run_at      DATETIME(3)  NULL,
          created_at  DATETIME(3)  NOT NULL,
          updated_at  DATETIME(3)  NOT NULL,
          PRIMARY KEY (id),
          UNIQUE KEY %s_uuid (uuid)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci|}
      table
      table
  | Postgresql ->
    Format.asprintf
      {|CREATE TABLE IF NOT EXISTS %s (
          id          BIGINT       GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
          uuid        UUID         NOT NULL,
          namespace   VARCHAR(128) NOT NULL,
          label       VARCHAR(256) NOT NULL,
          status      VARCHAR(16)  NOT NULL DEFAULT 'applied'
                      CONSTRAINT %s_status CHECK (status IN ('applied', 'failed')),
          last_error  TEXT         NULL,
          run_at      TIMESTAMPTZ  NULL,
          created_at  TIMESTAMPTZ  NOT NULL,
          updated_at  TIMESTAMPTZ  NOT NULL,
          CONSTRAINT %s_uuid UNIQUE (uuid)
        )|}
      table
      table
      table
;;

let column_exists dialect =
  match dialect with
  | Mariadb ->
    "SELECT COUNT(*) FROM information_schema.columns WHERE table_schema = DATABASE() AND \
     table_name = ? AND column_name = ?"
  | Postgresql ->
    "SELECT COUNT(*) FROM information_schema.columns WHERE table_schema = ANY \
     (current_schemas(false)) AND table_name = LOWER(?) AND column_name = LOWER(?)"
;;

let primary_key_name dialect =
  match dialect with
  | Mariadb ->
    "SELECT constraint_name FROM information_schema.table_constraints WHERE table_schema \
     = DATABASE() AND table_name = ? AND constraint_type = 'PRIMARY KEY'"
  | Postgresql ->
    "SELECT constraint_name FROM information_schema.table_constraints WHERE table_schema \
     = ANY (current_schemas(false)) AND table_name = LOWER(?) AND constraint_type = \
     'PRIMARY KEY'"
;;

let upgrade_migration_table dialect ~table ~primary_key =
  match dialect with
  | Mariadb ->
    (* DDL commits on its own: the rows are numbered into a column of
       their own first, which a rerun picks up, then one statement makes it
       [id] and the layout current *)
    [ Format.asprintf
        "ALTER TABLE %s ADD COLUMN IF NOT EXISTS veins_seq BIGINT NULL"
        table
    ; Format.asprintf
        "UPDATE %s AS s JOIN (SELECT id, ROW_NUMBER() OVER (ORDER BY created_at, id) AS \
         n FROM %s) AS r ON s.id = r.id SET s.veins_seq = r.n"
        table
        table
    ; Format.asprintf
        {|ALTER TABLE %s
            CHANGE id uuid BINARY(16) NOT NULL,
            DROP PRIMARY KEY,
            CHANGE veins_seq id BIGINT NOT NULL AUTO_INCREMENT FIRST,
            ADD PRIMARY KEY (id),
            ADD UNIQUE KEY %s_uuid (uuid),
            ADD COLUMN status ENUM('applied','failed') NOT NULL DEFAULT 'applied' AFTER label,
            ADD COLUMN last_error TEXT NULL AFTER status,
            ADD COLUMN run_at DATETIME(3) NULL AFTER last_error|}
        table
        table
    ]
  | Postgresql ->
    [ Format.asprintf "ALTER TABLE %s RENAME COLUMN id TO uuid" table
    ; Format.asprintf "ALTER TABLE %s DROP CONSTRAINT \"%s\"" table primary_key
    ; Format.asprintf
        {|ALTER TABLE %s
            ADD COLUMN id BIGINT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
            ADD CONSTRAINT %s_uuid UNIQUE (uuid),
            ADD COLUMN status VARCHAR(16) NOT NULL DEFAULT 'applied'
              CONSTRAINT %s_status CHECK (status IN ('applied', 'failed')),
            ADD COLUMN last_error TEXT NULL,
            ADD COLUMN run_at TIMESTAMPTZ NULL|}
        table
        table
        table
      (* the identity numbered the rows in storage order: renumber them by
         [created_at], through negative ids since the key is checked per
         row; the sequence already stands after the last *)
    ; Format.asprintf "UPDATE %s SET id = -id" table
    ; Format.asprintf
        "UPDATE %s AS s SET id = r.n FROM (SELECT uuid, ROW_NUMBER() OVER (ORDER BY \
         created_at, uuid) AS n FROM %s) AS r WHERE s.uuid = r.uuid"
        table
        table
    ; Format.asprintf "ALTER TABLE %s ALTER COLUMN id SET GENERATED ALWAYS" table
    ]
;;

let select_state_rows dialect ~table =
  Format.asprintf
    "SELECT id, %s AS uuid, namespace, label, status, last_error, COALESCE(run_at, \
     created_at) FROM %s ORDER BY id"
    (uuid_select_fragment dialect ~field:"uuid")
    table
;;

let select_state_rows_v1 dialect ~table =
  Format.asprintf
    "SELECT NULL, %s AS uuid, namespace, label, 'applied', NULL, created_at FROM %s \
     ORDER BY created_at"
    (uuid_select_fragment dialect ~field:"id")
    table
;;

let upsert_step_row dialect ~table =
  match dialect with
  | Mariadb ->
    Format.asprintf
      "INSERT INTO %s (uuid, namespace, label, status, last_error, run_at, created_at, \
       updated_at) VALUES (%s, ?, ?, ?, ?, ?, ?, ?) ON DUPLICATE KEY UPDATE status = \
       VALUES(status), last_error = VALUES(last_error), run_at = VALUES(run_at), \
       updated_at = VALUES(updated_at)"
      table
      (uuid_value_fragment dialect "?")
  | Postgresql ->
    Format.asprintf
      "INSERT INTO %s AS s (uuid, namespace, label, status, last_error, run_at, \
       created_at, updated_at) VALUES (%s, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT (uuid) DO \
       UPDATE SET status = EXCLUDED.status, last_error = EXCLUDED.last_error, run_at = \
       EXCLUDED.run_at, updated_at = EXCLUDED.updated_at"
      table
      (uuid_value_fragment dialect "?")
;;

let insert_step_row_if_missing dialect ~table =
  match dialect with
  | Mariadb ->
    Format.asprintf
      "INSERT INTO %s (uuid, namespace, label, status, last_error, run_at, created_at, \
       updated_at) VALUES (%s, ?, ?, ?, ?, ?, ?, ?) ON DUPLICATE KEY UPDATE uuid = uuid"
      table
      (uuid_value_fragment dialect "?")
  | Postgresql ->
    Format.asprintf
      "INSERT INTO %s (uuid, namespace, label, status, last_error, run_at, created_at, \
       updated_at) VALUES (%s, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT (uuid) DO NOTHING"
      table
      (uuid_value_fragment dialect "?")
;;

(* A UUID as an SQL literal, for statements printed for an admin to run. *)
let uuid_literal dialect uuid =
  let quoted = "'" ^ CCString.replace ~sub:"'" ~by:"''" uuid ^ "'" in
  match dialect with
  | Mariadb -> Format.asprintf "UNHEX(REPLACE(%s, '-', ''))" quoted
  | Postgresql -> quoted
;;

let repair_mark_applied dialect ~table ~uuid =
  Format.asprintf
    "UPDATE %s SET status = 'applied' WHERE uuid = %s"
    table
    (uuid_literal dialect uuid)
;;

let repair_delete dialect ~table ~uuid =
  Format.asprintf "DELETE FROM %s WHERE uuid = %s" table (uuid_literal dialect uuid)
;;

let request policy request_type sql =
  Caqti.Template.Request.create policy request_type (fun dialect ->
    Caqti.Template.Query.parse (sql (kind dialect)))
;;

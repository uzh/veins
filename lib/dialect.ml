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
          id          BINARY(16)   NOT NULL,
          namespace   VARCHAR(128) NOT NULL,
          label       VARCHAR(256) NOT NULL,
          created_at  DATETIME(3)  NOT NULL,
          updated_at  DATETIME(3)  NOT NULL,
          PRIMARY KEY (id)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci|}
      table
  | Postgresql ->
    Format.asprintf
      {|CREATE TABLE IF NOT EXISTS %s (
          id          UUID         NOT NULL,
          namespace   VARCHAR(128) NOT NULL,
          label       VARCHAR(256) NOT NULL,
          created_at  TIMESTAMPTZ  NOT NULL,
          updated_at  TIMESTAMPTZ  NOT NULL,
          PRIMARY KEY (id)
        )|}
      table
;;

let select_applied_ids dialect ~table =
  Format.asprintf
    "SELECT %s AS id FROM %s"
    (uuid_select_fragment dialect ~field:"id")
    table
;;

let select_applied_rows dialect ~table =
  Format.asprintf
    "SELECT %s AS id, namespace FROM %s"
    (uuid_select_fragment dialect ~field:"id")
    table
;;

let insert_applied_step dialect ~table =
  Format.asprintf
    "INSERT INTO %s (id, namespace, label, created_at, updated_at) VALUES (%s, ?, ?, ?, \
     ?)"
    table
    (uuid_value_fragment dialect "?")
;;

let delete_applied_step dialect ~table =
  Format.asprintf "DELETE FROM %s WHERE id = %s" table (uuid_value_fragment dialect "?")
;;

let request policy request_type sql =
  Caqti.Template.Request.create policy request_type (fun dialect ->
    Caqti.Template.Query.parse (sql (kind dialect)))
;;

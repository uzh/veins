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
  | Mariadb -> Some (Format.asprintf "SET FOREIGN_KEY_CHECKS = %d" (Bool.to_int enabled))
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

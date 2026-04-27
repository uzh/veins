module type Sig = sig
  val create_migration_table : table:string -> string
  val fk_checks_supported : bool
  val select_applied_ids : table:string -> string
  val select_applied_rows : table:string -> string
  val insert_applied_step : table:string -> string
  val delete_applied_step : table:string -> string
end

module Mariadb : Sig = struct
  let create_migration_table ~table =
    Format.asprintf
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
  let select_applied_ids ~table = Format.asprintf "SELECT id FROM %s" table
  let select_applied_rows ~table = Format.asprintf "SELECT id, namespace FROM %s" table

  let insert_applied_step ~table =
    Format.asprintf
      "INSERT INTO %s (id, namespace, label, created_at, updated_at) VALUES (?, ?, ?, ?, \
       ?)"
      table
  ;;

  let delete_applied_step ~table = Format.asprintf "DELETE FROM %s WHERE id = ?" table
end

module Postgresql : Sig = struct
  let create_migration_table ~table =
    Format.asprintf
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
  let select_applied_ids ~table = Format.asprintf "SELECT id FROM %s" table
  let select_applied_rows ~table = Format.asprintf "SELECT id, namespace FROM %s" table

  let insert_applied_step ~table =
    Format.asprintf
      "INSERT INTO %s (id, namespace, label, created_at, updated_at) VALUES (?, ?, ?, ?, \
       ?)"
      table
  ;;

  let delete_applied_step ~table = Format.asprintf "DELETE FROM %s WHERE id = ?" table
end

let of_url url =
  match Uri.scheme (Entity.Url.to_uri url) with
  | Some ("mariadb" | "mysql") -> Some (module Mariadb : Sig)
  | Some ("postgresql" | "postgres") -> Some (module Postgresql : Sig)
  | _ -> None
;;

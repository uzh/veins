module type Sig = sig
  val session_setup : string list
  val is_connection_error : Caqti_error.t -> bool
  val is_permission_error : Caqti_error.t -> bool
  val after_rollback : string list
  val create_migration_table : table:string -> string
  val fk_checks_supported : bool
  val select_applied_ids : table:string -> string
  val select_applied_rows : table:string -> string
  val insert_applied_step : table:string -> string
  val delete_applied_step : table:string -> string
  val insert_row : table:string -> columns:string list -> string
  val uuid_select_fragment : field:string -> string
  val uuid_value_fragment : string -> string
end

let is_connection_error : Caqti_error.t -> bool = function
  | #Caqti_error.load_or_connect -> true
  | `Request_failed _
  | `Response_failed _
  | `Encode_rejected _
  | `Encode_failed _
  | `Decode_rejected _
  | `Response_rejected _ -> false
;;

let insert_row ~table ~columns =
  let cols = CCString.concat ", " columns in
  let placeholders = CCString.concat ", " (CCList.map (Fun.const "?") columns) in
  Format.asprintf "INSERT INTO %s (%s) VALUES (%s)" table cols placeholders
;;

module Mariadb : Sig = struct
  let session_setup = [ "SET time_zone = '+00:00'" ]
  let is_connection_error = is_connection_error
  let is_permission_error (_ : Caqti_error.t) = false
  let after_rollback = [ "SET autocommit = 1" ]

  let uuid_select_fragment ~field =
    Format.asprintf
      "LOWER(CONCAT(SUBSTR(HEX(%s),1,8),'-',SUBSTR(HEX(%s),9,4),'-',SUBSTR(HEX(%s),13,4),'-',SUBSTR(HEX(%s),17,4),'-',SUBSTR(HEX(%s),21)))"
      field
      field
      field
      field
      field
  ;;

  let uuid_value_fragment name = Format.asprintf "UNHEX(REPLACE(%s,'-',''))" name

  let create_migration_table ~table =
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
  ;;

  let fk_checks_supported = true

  let select_applied_ids ~table =
    Format.asprintf "SELECT %s AS id FROM %s" (uuid_select_fragment ~field:"id") table
  ;;

  let select_applied_rows ~table =
    Format.asprintf
      "SELECT %s AS id, namespace FROM %s"
      (uuid_select_fragment ~field:"id")
      table
  ;;

  let insert_applied_step ~table =
    Format.asprintf
      "INSERT INTO %s (id, namespace, label, created_at, updated_at) VALUES (%s, ?, ?, \
       ?, ?)"
      table
      (uuid_value_fragment "?")
  ;;

  let delete_applied_step ~table =
    Format.asprintf "DELETE FROM %s WHERE id = %s" table (uuid_value_fragment "?")
  ;;

  let insert_row = insert_row
end

module Postgresql : Sig = struct
  let session_setup = [ "SET TIME ZONE 'UTC'" ]
  let is_connection_error = is_connection_error
  let is_permission_error (_ : Caqti_error.t) = false
  let after_rollback = []
  let uuid_select_fragment ~field = Format.asprintf "%s::text" field
  let uuid_value_fragment name = Format.asprintf "%s::uuid" name

  let create_migration_table ~table =
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

  let fk_checks_supported = false

  let select_applied_ids ~table =
    Format.asprintf "SELECT %s AS id FROM %s" (uuid_select_fragment ~field:"id") table
  ;;

  let select_applied_rows ~table =
    Format.asprintf
      "SELECT %s AS id, namespace FROM %s"
      (uuid_select_fragment ~field:"id")
      table
  ;;

  let insert_applied_step ~table =
    Format.asprintf
      "INSERT INTO %s (id, namespace, label, created_at, updated_at) VALUES (%s, ?, ?, \
       ?, ?)"
      table
      (uuid_value_fragment "?")
  ;;

  let delete_applied_step ~table =
    Format.asprintf "DELETE FROM %s WHERE id = %s" table (uuid_value_fragment "?")
  ;;

  let insert_row = insert_row
end

let of_url url =
  match Uri.scheme (Entity.Url.to_uri url) with
  | Some ("mariadb" | "mysql") -> Some (module Mariadb : Sig)
  | Some ("postgresql" | "postgres") -> Some (module Postgresql : Sig)
  | _ -> None
;;

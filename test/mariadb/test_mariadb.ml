(** Integration tests against a live MariaDB, see [MARIADB_URL] and the
    per-role [MARIADB_*_URL] variables in the README. *)

module Suite = Suite.Make (struct
    let env = "MARIADB"
    let default_url = "mariadb://admin:password@database-mariadb/development"
    let default_port = 3306

    module Db = Veins.Pools.Make (struct
        let database () =
          Veins.Database.create
            (Veins.Label.create "root")
            (Veins.Url.create
               (Suite.env_opt "MARIADB_URL" |> CCOption.value ~default:default_url))
        ;;

        let database_pool_size = 5
        let expected_databases = 4

        module Driver = Veins_mariadb.Driver
      end)

    let utc_offset_sql = "SELECT TIMESTAMPDIFF(SECOND, UTC_TIMESTAMP(), NOW())"
    let connection_id_sql = "SELECT CONNECTION_ID()"
    let current_user_sql = "SELECT CURRENT_USER()"
    let statement_timeout_sql = "SELECT CAST(@@max_statement_time AS SIGNED)"
  end)

let () = Suite.run "Veins MariaDB"

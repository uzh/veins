(** Integration tests against a live PostgreSQL, see [POSTGRES_URL] and the
    per-role [POSTGRES_*_URL] variables in the README. *)

module Suite = Suite.Make (struct
    let env = "POSTGRES"
    let default_url = "postgresql://root:root@database-postgres/development"
    let default_port = 5432

    module Db = Veins.Pools.Make (struct
        let database =
          Veins.Database.create
            (Veins.Label.create "root")
            (Veins.Url.create
               (Suite.env_opt "POSTGRES_URL" |> CCOption.value ~default:default_url))
        ;;

        let database_pool_size = 5
        let expected_databases = 4

        module Driver = Veins_postgresql.Driver
      end)

    let utc_offset_sql = "SELECT EXTRACT(TIMEZONE FROM now())::int"
    let connection_id_sql = "SELECT pg_backend_pid()"
    let current_user_sql = "SELECT CURRENT_USER::text"

    let statement_timeout_sql =
      "SELECT setting::int / 1000 FROM pg_settings WHERE name = 'statement_timeout'"
    ;;
  end)

let () = Suite.run "Veins PostgreSQL"

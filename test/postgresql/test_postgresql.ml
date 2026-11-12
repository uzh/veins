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
            (Veins.Database.Main
               (Veins.Url.create
                  (Suite.env_opt "POSTGRES_URL" |> CCOption.value ~default:default_url)))
        ;;

        let database_pool_size = 5
        let expected_databases = 4

        module Dialect = Veins_postgresql.Dialect
      end)

    let utc_offset_sql = "SELECT EXTRACT(TIMEZONE FROM now())::int"
    let connection_id_sql = "SELECT pg_backend_pid()"
    let current_user_sql = "SELECT CURRENT_USER::text"
  end)

let () = Suite.run "Veins PostgreSQL"

(** PostgreSQL driver package for Veins.

    Depending on [veins-postgresql] in your opam file brings in
    [caqti-driver-postgresql] transitively — no other dependency entry needed.

    {[
      module Db = Veins_postgresql.Pools.Make (struct
        let database = Veins.Database.create (Veins.Label.create "root") url
      end)
    ]}

    [database_pool_size] defaults to [10] and [expected_databases] to [5].
    For custom values use {!Veins.Pools.Make} directly with
    [module Dialect = Veins_postgresql.Dialect]. *)

(** PostgreSQL dialect implementation — forwards to {!Veins.Dialect.Postgresql}. *)
module Dialect = Veins.Dialect.Postgresql

(** Connection-pool functor with the PostgreSQL dialect pre-configured.

    Only [database] is required; [database_pool_size] defaults to [10] and
    [expected_databases] defaults to [5].  Use instead of [Veins.Pools.Make]
    to avoid specifying the dialect manually:

    {[
      module Db = Veins_postgresql.Pools.Make (struct
        let database = Veins.Database.create (Veins.Label.create "root") url
      end)
    ]}

    For custom pool sizes, use {!Veins.Pools.Make} directly with
    [module Dialect = Veins_postgresql.Dialect] in your config.

    The [database] URL must use the [postgresql://] or [postgres://] scheme;
    use {!Veins.Dialect.of_url} to validate this at runtime if needed. *)
module Pools = struct
  module Make (C : sig
    val database : Veins.Database.t
  end) =
    Veins.Pools.Make (struct
      let database = C.database
      let database_pool_size = 10
      let expected_databases = 5
      module Dialect = Veins.Dialect.Postgresql
    end)
end

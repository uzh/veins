(** PostgreSQL driver package for Vena.

    Depending on [vena-postgresql] in your opam file brings in
    [caqti-driver-postgresql] transitively — no other dependency entry needed.

    {[
      module Db = Vena_postgresql.Pools.Make (struct
        let database = Vena.Database.create (Vena.Label.create "root") url
      end)
    ]}

    [database_pool_size] defaults to [10] and [expected_databases] to [5].
    For custom values use {!Vena.Pools.Make} directly with
    [module Dialect = Vena_postgresql.Dialect]. *)

(** PostgreSQL dialect implementation — forwards to {!Vena.Dialect.Postgresql}. *)
module Dialect = Vena.Dialect.Postgresql

(** Connection-pool functor with the PostgreSQL dialect pre-configured.

    Only [database] is required; [database_pool_size] defaults to [10] and
    [expected_databases] defaults to [5].  Use instead of [Vena.Pools.Make]
    to avoid specifying the dialect manually:

    {[
      module Db = Vena_postgresql.Pools.Make (struct
        let database = Vena.Database.create (Vena.Label.create "root") url
      end)
    ]}

    For custom pool sizes, use {!Vena.Pools.Make} directly with
    [module Dialect = Vena_postgresql.Dialect] in your config.

    The [database] URL must use the [postgresql://] or [postgres://] scheme;
    use {!Vena.Dialect.of_url} to validate this at runtime if needed. *)
module Pools = struct
  module Make (C : sig
    val database : Vena.Database.t
  end) =
    Vena.Pools.Make (struct
      let database = C.database
      let database_pool_size = 10
      let expected_databases = 5
      module Dialect = Vena.Dialect.Postgresql
    end)
end

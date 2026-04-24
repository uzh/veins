(** MariaDB driver package for Vena.

    Depending on [vena-mariadb] in your opam file brings in
    [caqti-driver-mariadb] transitively — no other dependency entry needed.

    {[
      module Db = Vena_mariadb.Pools.Make (struct
        let database = Vena.Database.create (Vena.Label.create "root") url
      end)
    ]}

    [database_pool_size] defaults to [10] and [expected_databases] to [5].
    For custom values use {!Vena.Pools.Make} directly with
    [module Dialect = Vena_mariadb.Dialect]. *)

(** MariaDB dialect implementation — forwards to {!Vena.Dialect.Mariadb}. *)
module Dialect = Vena.Dialect.Mariadb

(** Connection-pool functor with the MariaDB dialect pre-configured.

    Only [database] is required; [database_pool_size] defaults to [10] and
    [expected_databases] defaults to [5].  Use instead of [Vena.Pools.Make]
    to avoid specifying the dialect manually:

    {[
      module Db = Vena_mariadb.Pools.Make (struct
        let database = Vena.Database.create (Vena.Label.create "root") url
      end)
    ]}

    For custom pool sizes, use {!Vena.Pools.Make} directly with
    [module Dialect = Vena_mariadb.Dialect] in your config.

    The [database] URL must use the [mariadb://] or [mysql://] scheme;
    use {!Vena.Dialect.of_url} to validate this at runtime if needed. *)
module Pools = struct
  module Make (C : sig
    val database : Vena.Database.t
  end) =
    Vena.Pools.Make (struct
      let database = C.database
      let database_pool_size = 10
      let expected_databases = 5
      module Dialect = Vena.Dialect.Mariadb
    end)
end

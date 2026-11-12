(** PostgreSQL driver package for Veins.

    Depending on [veins-postgresql] in your opam file brings in
    [caqti-driver-postgresql] transitively — no other dependency entry needed.

    {[
    module Db = Veins_postgresql.Pools.Make (struct
        let database =
          Veins.Database.create (Veins.Label.create "root") (Veins.Database.Main url)
        ;;
      end)
    ]}

    [database_pool_size] defaults to [10] and [expected_databases] to [5].
    For custom values use {!Veins.Pools.Make} directly with
    [module Dialect = Veins_postgresql.Dialect]. *)

(** PostgreSQL dialect: {!Veins.Dialect.Postgresql}, plus the driver's errors
    that mean the connection is gone. *)
module Dialect : Veins.Dialect.Sig = struct
  include Veins.Dialect.Postgresql

  (* SQLSTATE class 08 (connection exception) and 57P01-57P03 (admin/crash
     shutdown, cannot connect now). *)
  let is_connection_sqlstate sqlstate =
    CCString.prefix ~pre:"08" sqlstate
    || CCList.mem sqlstate [ "57P01"; "57P02"; "57P03" ]
  ;;

  let is_connection_error : Caqti_error.t -> bool = function
    | `Request_failed { Caqti_error.msg; _ }
    | `Response_failed { Caqti_error.msg; _ }
    | `Response_rejected { Caqti_error.msg; _ } ->
      (match[@warning "-4"] msg with
       | Caqti_driver_postgresql.Connection_error_msg { connection_status; _ } ->
         connection_status = Postgresql.Bad
       | Caqti_driver_postgresql.Result_error_msg { sqlstate; _ } ->
         is_connection_sqlstate sqlstate
       | _ -> false)
    | error -> is_connection_error error
  ;;
end

(** Connection-pool functor with the PostgreSQL dialect pre-configured.

    Only [database] is required; [database_pool_size] defaults to [10] and
    [expected_databases] defaults to [5].  Use instead of [Veins.Pools.Make]
    to avoid specifying the dialect manually:

    {[
    module Db = Veins_postgresql.Pools.Make (struct
        let database =
          Veins.Database.create (Veins.Label.create "root") (Veins.Database.Main url)
        ;;
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

      module Dialect = Dialect
    end)
end

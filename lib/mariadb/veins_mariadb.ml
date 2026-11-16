(** MariaDB driver library of Veins: [veins.mariadb] in dune.

    Part of the opam package [veins], installed when [caqti-driver-mariadb]
    is: depend on both in your opam file.

    {[
    module Db = Veins_mariadb.Pools.Make (struct
        let database = Veins.Database.create (Veins.Label.create "root") url
      end)
    ]}

    [database_pool_size] defaults to [10] and [expected_databases] to [5].
    For custom values use {!Veins.Pools.Make} directly with
    [module Dialect = Veins_mariadb.Dialect].

    With one database user for everything, {!Plain} gives the same pools
    without roles and needs. *)

(** MariaDB dialect: {!Veins.Dialect.Mariadb}, plus the driver's errors that
    mean the connection is gone. *)
module Dialect : Veins.Dialect.Sig = struct
  include Veins.Dialect.Mariadb

  (* Client errors (2xxx, e.g. 2006 server gone away, 2013 lost connection)
     and server-side terminations (1053 shutdown, 1927 killed, 4031 idle
     timeout). *)
  let is_connection_errno errno =
    (errno >= 2000 && errno < 3000) || CCList.mem errno [ 1053; 1927; 4031 ]
  ;;

  let is_connection_error : Caqti.Error.t -> bool = function
    | `Request_failed { Caqti.Error.msg; _ } | `Response_failed { Caqti.Error.msg; _ } ->
      (match[@warning "-4"] msg with
       | Caqti_driver_mariadb.Error_msg { errno; _ } -> is_connection_errno errno
       | _ -> false)
    | error -> is_connection_error error
  ;;

  (* 1044 database access denied, 1142 table, 1143 column, 1227 needs a
     privilege (e.g. SUPER), 1370 routine. *)
  let is_permission_errno errno = CCList.mem errno [ 1044; 1142; 1143; 1227; 1370 ]

  let is_permission_error : Caqti.Error.t -> bool = function
    | `Request_failed { Caqti.Error.msg; _ } | `Response_failed { Caqti.Error.msg; _ } ->
      (match[@warning "-4"] msg with
       | Caqti_driver_mariadb.Error_msg { errno; _ } -> is_permission_errno errno
       | _ -> false)
    | (_ : Caqti.Error.t) -> false
  ;;
end

(** Connection-pool functor with the MariaDB dialect pre-configured.

    Only [database] is required; [database_pool_size] defaults to [10] and
    [expected_databases] defaults to [5].  Use instead of [Veins.Pools.Make]
    to avoid specifying the dialect manually:

    {[
    module Db = Veins_mariadb.Pools.Make (struct
        let database = Veins.Database.create (Veins.Label.create "root") url
      end)
    ]}

    For custom pool sizes, use {!Veins.Pools.Make} directly with
    [module Dialect = Veins_mariadb.Dialect] in your config.

    The [database] URL must use the [mariadb://] or [mysql://] scheme;
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

(** Pools for one database user, with the MariaDB dialect pre-configured: no
    roles, logins or needs, see {!Veins.Plain}.

    {[
    module Db = Veins_mariadb.Plain.Make (struct
        let database = Veins.Database.create (Veins.Label.create "root") url
      end)

    let name = Db.find_opt (Db.label_ctx root) find_name 1
    ]} *)
module Plain = struct
  module Make (C : sig
      val database : Veins.Database.t
    end) =
    Veins.Plain.Make (Pools.Make (C))
end

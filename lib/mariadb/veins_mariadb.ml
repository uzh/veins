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
    [module Driver = Veins_mariadb.Driver].

    With one database user for everything, {!Plain} gives the same pools
    without roles and needs. *)

(** How veins reads the MariaDB driver's errors: lost connections and
    missing privileges. The SQL veins sends follows the connection's dialect,
    see {!Veins.Dialect}. *)
module Driver : Veins.Driver.Sig = struct
  include Veins.Driver.Generic

  (* Client errors (2xxx, e.g. 2006 server gone away, 2013 lost connection),
     server-side terminations (1053 shutdown, 1927 killed, 4031 idle timeout)
     and the server's network errors (1152 aborting connection, 1154-1161
     read / write errors and timeouts). Not 1153, a packet over
     max_allowed_packet: a new connection wouldn't take that statement
     either. *)
  let is_connection_errno errno =
    (errno >= 2000 && errno < 3000)
    || (errno >= 1154 && errno <= 1161)
    || CCList.mem errno [ 1053; 1152; 1927; 4031 ]
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

(** Connection-pool functor with the MariaDB driver pre-configured.

    Only [database] is required; [database_pool_size] defaults to [10] and
    [expected_databases] defaults to [5].  Use instead of [Veins.Pools.Make]
    to avoid specifying the driver manually:

    {[
    module Db = Veins_mariadb.Pools.Make (struct
        let database = Veins.Database.create (Veins.Label.create "root") url
      end)
    ]}

    For custom pool sizes, use {!Veins.Pools.Make} directly with
    [module Driver = Veins_mariadb.Driver] in your config. *)
module Pools = struct
  module Make (C : sig
      val database : Veins.Database.t
    end) =
  Veins.Pools.Make (struct
      let database = C.database
      let database_pool_size = 10
      let expected_databases = 5

      module Driver = Driver
    end)
end

(** Pools for one database user, with {!Driver} pre-configured: no roles,
    logins or needs, see {!Veins.Plain}.

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

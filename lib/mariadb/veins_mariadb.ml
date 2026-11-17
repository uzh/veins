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

module type CONFIG = sig
  val database : unit -> Veins.Database.t
  val database_pool_size : int
end

module Pools = struct
  module Make_with_options (C : CONFIG) (O : Veins.Pools_sig.OptionsSig) =
    Veins.Pools.Make_with_options
      (struct
        let database = C.database
        let database_pool_size = C.database_pool_size
        let expected_databases = 5

        module Driver = Driver
      end)
      (O)

  module Make (C : sig
      val database : unit -> Veins.Database.t
    end) =
    Make_with_options
      (struct
        let database = C.database
        let database_pool_size = 10
      end)
      (struct
        let options = Veins.Pool_options.default
      end)
end

module Plain = struct
  module Make_with_options (C : CONFIG) (O : Veins.Pools_sig.OptionsSig) =
    Veins.Plain.Make (Pools.Make_with_options (C) (O))

  module Make (C : sig
      val database : unit -> Veins.Database.t
    end) =
    Veins.Plain.Make (Pools.Make (C))
end

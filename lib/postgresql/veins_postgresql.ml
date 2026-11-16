module Driver : Veins.Driver.Sig = struct
  include Veins.Driver.Generic

  (* SQLSTATE class 08 (connection exception) and 57P01-57P03 (admin/crash
     shutdown, cannot connect now). *)
  let is_connection_sqlstate sqlstate =
    CCString.prefix ~pre:"08" sqlstate
    || CCList.mem sqlstate [ "57P01"; "57P02"; "57P03" ]
  ;;

  let is_connection_error : Caqti.Error.t -> bool = function
    | `Request_failed { Caqti.Error.msg; _ }
    | `Response_failed { Caqti.Error.msg; _ }
    | `Response_rejected { Caqti.Error.msg; _ } ->
      (match[@warning "-4"] msg with
       | Caqti_driver_postgresql.Connection_error_msg { connection_status; _ } ->
         connection_status = Postgresql.Bad
       | Caqti_driver_postgresql.Result_error_msg { sqlstate; _ } ->
         is_connection_sqlstate sqlstate
       | _ -> false)
    | error -> is_connection_error error
  ;;

  (* 42501 insufficient_privilege *)
  let is_permission_error : Caqti.Error.t -> bool = function
    | `Request_failed { Caqti.Error.msg; _ }
    | `Response_failed { Caqti.Error.msg; _ }
    | `Response_rejected { Caqti.Error.msg; _ } ->
      (match[@warning "-4"] msg with
       | Caqti_driver_postgresql.Result_error_msg { sqlstate; _ } ->
         CCString.equal sqlstate "42501"
       | _ -> false)
    | (_ : Caqti.Error.t) -> false
  ;;
end

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

module Plain = struct
  module Make (C : sig
      val database : Veins.Database.t
    end) =
    Veins.Plain.Make (Pools.Make (C))
end

module type Sig = sig
  val is_connection_error : Caqti.Error.t -> bool
  val is_permission_error : Caqti.Error.t -> bool
end

module Generic : Sig = struct
  let is_connection_error : Caqti.Error.t -> bool = function
    | #Caqti.Error.load_or_connect -> true
    | `Request_failed _
    | `Response_failed _
    | `Encode_rejected _
    | `Encode_failed _
    | `Decode_rejected _
    | `Response_rejected _ -> false
  ;;

  let is_permission_error (_ : Caqti.Error.t) = false
end

type t =
  | Connection_failed of string
  | Database_not_registered of string
  | Role_required of string
  | Role_not_configured of
      { label : string
      ; role : string
      }
  | Insufficient_capabilities of
      { label : string
      ; role : string option
      ; missing : string list
      }
  | Migration_failed of string
  | Unsupported of string

exception Exn of t

let show : t -> string = function
  | Connection_failed msg -> "Connection failed: " ^ msg
  | Database_not_registered label -> "Database not registered: " ^ label
  | Role_required label ->
    Format.asprintf
      "Database '%s' has one URL per role: the context must name a role"
      label
  | Role_not_configured { label; role } ->
    Format.asprintf "Role '%s' is not configured for database '%s'" role label
  | Insufficient_capabilities { label; role; missing } ->
    Format.asprintf
      "Statement on '%s' needs %s, which role '%s' doesn't have"
      label
      (CCString.concat ", " missing)
      (CCOption.value ~default:"(none)" role)
  | Migration_failed msg -> "Migration failed: " ^ msg
  | Unsupported msg -> "Unsupported: " ^ msg
;;

let pp fmt t = Format.pp_print_string fmt (show t)

type failure =
  { label : Entity.Label.t
  ; role : Entity.Role.t option
  ; error : Caqti_error.t
  }

exception Failed of failure

let () =
  Printexc.register_printer (function
    | Exn t -> Some (show t)
    | Failed { label; role; error } ->
      Some
        (Format.asprintf
           "Database %a%s: %a"
           Entity.Label.pp
           label
           (CCOption.map_or
              ~default:""
              (Format.asprintf " (role %a)" Entity.Role.pp)
              role)
           Caqti_error.pp
           error)
    | _ -> None)
;;

let failure ?role label error = { label; role; error }

let cause : Caqti_error.t -> Caqti_error.cause option = function
  | `Request_failed e -> Some (Caqti_error.cause (`Request_failed e))
  | `Response_failed e -> Some (Caqti_error.cause (`Response_failed e))
  | `Load_failed _
  | `Load_rejected _
  | `Connect_failed _
  | `Connect_rejected _
  | `Post_connect _
  | `Encode_rejected _
  | `Encode_failed _
  | `Decode_rejected _
  | `Response_rejected _ -> None
;;

let cause_of_exn = function
  | Failed { error; _ } | Caqti_error.Exn error -> cause error
  | _ -> None
;;

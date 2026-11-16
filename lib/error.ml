type t =
  | Connection_failed of string
  | Database_not_registered of string
  | Permission_denied of
      { label : string
      ; login : string
      ; role : string option
      ; needs : string list
      ; message : string
      }
  | Migration_failed of string
  | Unsupported of string

exception Exn of t

let show : t -> string = function
  | Connection_failed msg -> "Connection failed: " ^ msg
  | Database_not_registered label -> "Database not registered: " ^ label
  | Permission_denied { label; login; role; needs; message } ->
    Format.asprintf
      "Database '%s' refused login '%s'%s a statement declared to need %s; the login \
       lacks a grant its role claims: %s"
      label
      login
      (CCOption.map_or ~default:"" (Format.asprintf " (role '%s')") role)
      (match needs with
       | [] -> "nothing"
       | needs -> CCString.concat ", " needs)
      message
  | Migration_failed msg -> "Migration failed: " ^ msg
  | Unsupported msg -> "Unsupported: " ^ msg
;;

let pp fmt t = Format.pp_print_string fmt (show t)

type failure =
  { label : Entity.Label.t
  ; login : Entity.Login.t
  ; role : string option
  ; error : Caqti_error.t
  }

exception Failed of failure

let () =
  Printexc.register_printer (function
    | Exn t -> Some (show t)
    | Failed { label; login; role; error } ->
      Some
        (Format.asprintf
           "Database %a (login %a%s): %a"
           Entity.Label.pp
           label
           Entity.Login.pp
           login
           (CCOption.map_or ~default:"" (Format.asprintf ", role %s") role)
           Caqti_error.pp
           error)
    | _ -> None)
;;

let failure ?role ~login label error = { label; login; role; error }

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

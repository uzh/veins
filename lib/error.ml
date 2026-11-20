type t =
  | Connection_failed of string
  | Acquire_timeout of string
  | Database_not_registered of string
  | Permission_denied of
      { label : string
      ; login : string
      ; role : string option
      ; needs : string list
      ; message : string
      }
  | Login_not_configured of
      { label : string
      ; login : string
      }
  | Migration_failed of string
  | Migration_not_clean of (string * string) list
  | Unsupported of string

exception Exn of t

let show : t -> string = function
  | Connection_failed msg -> "Connection failed: " ^ msg
  | Acquire_timeout msg -> "No free connection: " ^ msg
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
  | Login_not_configured { label; login } ->
    Format.asprintf
      "Database '%s' has no URL for login '%s', and its logins may not connect as the \
       owner"
      label
      login
  | Migration_failed msg -> "Migration failed: " ^ msg
  | Migration_not_clean databases ->
    Format.asprintf
      "Not migrated, run the migrations or repair a failed step by hand: %s"
      (CCString.concat
         "; "
         (CCList.map (fun (label, status) -> label ^ ": " ^ status) databases))
  | Unsupported msg -> "Unsupported: " ^ msg
;;

let pp fmt t = Format.pp_print_string fmt (show t)

type failure =
  { label : Entity.Label.t
  ; login : Entity.Login.t
  ; role : string option
  ; error : Caqti.Error.t
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
           Caqti.Error.pp
           error)
    | _ -> None)
;;

let failure ?role ~login label error = { label; login; role; error }

let cause : Caqti.Error.t -> Caqti.Error.cause option = function
  | `Request_failed e -> Some (Caqti.Error.cause (`Request_failed e))
  | `Response_failed e -> Some (Caqti.Error.cause (`Response_failed e))
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
  | Failed { error; _ } | Caqti.Error.Exn error -> cause error
  | _ -> None
;;

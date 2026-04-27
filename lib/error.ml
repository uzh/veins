type t =
  | Connection_failed of string
  | Not_found of string
  | Database_not_registered of string
  | Migration_failed of string
  | Caqti_error of string
  | Unsupported of string

exception Exn of t

let show : t -> string = function
  | Connection_failed msg -> "Connection failed: " ^ msg
  | Not_found label -> "Not found: " ^ label
  | Database_not_registered label -> "Database not registered: " ^ label
  | Migration_failed msg -> "Migration failed: " ^ msg
  | Caqti_error msg -> "Caqti error: " ^ msg
  | Unsupported msg -> "Unsupported: " ^ msg
;;

let pp fmt t = Format.pp_print_string fmt (show t)

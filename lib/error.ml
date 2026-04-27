type t =
  | Connection_failed of string
  | Database_not_registered of string
  | Migration_failed of string
  | Caqti_error of string

exception Exn of t

let show : t -> string = function
  | Connection_failed msg -> "Connection failed: " ^ msg
  | Database_not_registered label -> "Database not registered: " ^ label
  | Migration_failed msg -> "Migration failed: " ^ msg
  | Caqti_error msg -> "Caqti error: " ^ msg
;;

let pp fmt t = Format.pp_print_string fmt (show t)

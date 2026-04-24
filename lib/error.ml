(** Error types for the Vena database library. *)

type t =
  | Connection_failed of string
      (** A connection attempt failed, e.g. bad URL or server unreachable. *)
  | Not_found of string
      (** A required row was not returned by a query. *)
  | Database_not_registered of string
      (** [fetch] was called for a label that was never registered with
          [Pool.initialize] or [Pool.add]. *)
  | Migration_failed of string
      (** A migration step returned an error or the state is dirty. *)
  | Caqti_error of string
      (** A Caqti driver error (string representation). *)
  | Unsupported of string
      (** An operation that is not supported in the current context. *)

exception Exn of t
(** Raised by query helpers when an unrecoverable error occurs. *)

let show : t -> string = function
  | Connection_failed msg -> "Connection failed: " ^ msg
  | Not_found label -> "Not found: " ^ label
  | Database_not_registered label -> "Database not registered: " ^ label
  | Migration_failed msg -> "Migration failed: " ^ msg
  | Caqti_error msg -> "Caqti error: " ^ msg
  | Unsupported msg -> "Unsupported: " ^ msg
;;

let pp fmt t = Format.pp_print_string fmt (show t)

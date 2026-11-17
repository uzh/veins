(** The text of a generated migration file, without I/O or randomness, so it
    can be tested. *)

(** The dialects a generated step has SQL placeholders for. *)
type dialects =
  | Both
  | Only of Veins.Dialect.kind

(** ["both"], ["mariadb"] or ["postgresql"]. *)
val dialects_of_string : string -> dialects option

(** [steps] fresh v4 UUIDs from [rng]. *)
val random_ids : Random.State.t -> steps:int -> string list

(** [2026-04-24T14:03:14Z]. *)
val iso8601 : Ptime.t -> string

(** [20260424140314], for file names. *)
val compact_timestamp : Ptime.t -> string

(** Lower-case alphanumeric words joined by [_]. *)
val slugify : string -> string

(** [add_users_table] is [AddUsersTable]; a leading digit gets a [Migration]
    prefix. *)
val module_name_of_slug : string -> string

(** The file: one step per id (in order), the migration adding them, and its
    registration.

    Raises [Invalid_argument] when [ids] is empty. *)
val render
  :  module_name:string
  -> namespace:string
  -> written_at:Ptime.t
  -> dialects:dialects
  -> ids:string list
  -> string

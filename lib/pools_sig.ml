module type ConfigSig = sig
  val database : Entity.Database.t
  val database_pool_size : int
  val expected_databases : int

  module Dialect : Dialect.Sig
end

module type Sig = sig
  module Config : ConfigSig

  module Pool : sig
    val initialize : ?additional_pools:Entity.Database.t list -> unit -> unit
    val add : ?required:bool -> Entity.Database.t -> unit
    val reset : ?required:bool -> Entity.Database.t -> unit Lwt.t
    val drop : Entity.Label.t -> unit Lwt.t
    val clear : unit -> unit

    val fetch
      :  ?retries:int
      -> Entity.Label.t
      -> (Caqti_lwt.connection, Caqti_error.t) Caqti_lwt_unix.Pool.t Lwt.t

    val connect : Entity.Label.t -> (unit, Error.t) result
    val disconnect : Entity.Label.t -> unit Lwt.t
    val reset_label : ?required:bool -> Entity.Label.t -> Entity.Database.t -> unit Lwt.t

    val find_all
      :  ?allowed_status:Entity.Status.t list
      -> ?exclude:Entity.Label.t list
      -> unit
      -> Entity.Database.t list

    val raise_caqti_error : Entity.Label.t -> ('a, Caqti_error.t) Lwt_result.t -> 'a Lwt.t
  end

  val query
    :  Entity.Label.t
    -> (Caqti_lwt.connection -> ('a, Caqti_error.t) Lwt_result.t)
    -> 'a Lwt.t

  val exec : Entity.Label.t -> ('a, unit, [ `Zero ]) Caqti_request.t -> 'a -> unit Lwt.t

  val collect
    :  Entity.Label.t
    -> ('a, 'b, [< `Zero | `One | `Many ]) Caqti_request.t
    -> 'a
    -> 'b list Lwt.t

  val find : Entity.Label.t -> ('a, 'b, [< `One ]) Caqti_request.t -> 'a -> 'b Lwt.t

  val find_opt
    :  Entity.Label.t
    -> ('a, 'b, [< `Zero | `One ]) Caqti_request.t
    -> 'a
    -> 'b option Lwt.t

  val populate
    :  Entity.Label.t
    -> string
    -> string list
    -> 'a Caqti_type.t
    -> 'a list
    -> unit Lwt.t

  val transaction
    :  ?setup:(Caqti_lwt.connection -> (unit, Caqti_error.t) Lwt_result.t) list
    -> ?cleanup:(Caqti_lwt.connection -> (unit, Caqti_error.t) Lwt_result.t) list
    -> Entity.Label.t
    -> (Caqti_lwt.connection -> ('a, Caqti_error.t) Lwt_result.t)
    -> 'a Lwt.t

  val transaction_iter
    :  Entity.Label.t
    -> (Caqti_lwt.connection -> (unit, Caqti_error.t) Lwt_result.t) list
    -> unit Lwt.t
end

type all

let role : all Entity.Role.t = Entity.Role.owner
let needs : all Entity.Need.t = Entity.Need.none

module Ctx = struct
  type no_transaction = Ctx.no_transaction
  type transaction = Ctx.transaction
  type 'txn t = ('txn, all) Ctx.t
  type any = Any : 'maybe_txn t -> any [@@ocaml.unboxed]

  let txn = Ctx.txn
  let is_transaction = Ctx.is_transaction
  let label = Ctx.label
  let tags = Ctx.tags
  let after_commit = Ctx.after_commit
  let label_tag = Ctx.label_tag
  let with_roles ctx = Ctx.Internal.with_role ~role:Entity.Role.owner ctx
end

module type Sig = sig
  module With_roles : Pools_sig.Sig

  val options : Pool_options.t

  module Pool : sig
    val initialize : ?additional_pools:Entity.Database.t list -> unit -> unit
    val add : ?required:bool -> Entity.Database.t -> unit
    val reset : ?required:bool -> Entity.Database.t -> unit
    val drop : Entity.Label.t -> unit
    val clear : unit -> unit
    val find : Entity.Label.t -> Entity.Database.t option

    val find_all
      :  ?allowed_status:Entity.Status.t list
      -> ?exclude:Entity.Label.t list
      -> unit
      -> Entity.Database.t list

    val fetch
      :  Entity.Label.t
      -> (Caqti_lwt.connection, Caqti.Error.t) Caqti_lwt_unix.Pool.t Lwt.t

    val connect : Entity.Label.t -> (unit, Error.t) result
    val ping : Entity.Label.t -> (unit, Error.t) Lwt_result.t
    val test : Entity.Database.t -> (unit, Error.t) Lwt_result.t
    val disconnect : ?error:Caqti.Error.t -> Entity.Label.t -> unit
  end

  val label_ctx : ?tags:Logs.Tag.set -> Entity.Label.t -> Ctx.no_transaction Ctx.t

  val connection_ctx
    :  ?tags:Logs.Tag.set
    -> Entity.Label.t
    -> (Ctx.no_transaction Ctx.t -> 'a Lwt.t)
    -> 'a Lwt.t

  val transaction_ctx
    :  ?tags:Logs.Tag.set
    -> Entity.Label.t
    -> (Ctx.transaction Ctx.t -> 'a Lwt.t)
    -> 'a Lwt.t

  val with_transaction : _ Ctx.t -> (Ctx.transaction Ctx.t -> 'a Lwt.t) -> 'a Lwt.t

  val query
    :  _ Ctx.t
    -> (Caqti_lwt.connection -> ('a, Caqti.Error.t) Lwt_result.t)
    -> 'a Lwt.t

  val exec
    :  _ Ctx.t
    -> ('a, unit, [< `Zero ]) Caqti.Template.Request.t
    -> 'a
    -> unit Lwt.t

  val collect
    :  _ Ctx.t
    -> ('a, 'b, [< `Zero | `One | `Many ]) Caqti.Template.Request.t
    -> 'a
    -> 'b list Lwt.t

  val find : _ Ctx.t -> ('a, 'b, [< `One ]) Caqti.Template.Request.t -> 'a -> 'b Lwt.t

  val find_opt
    :  _ Ctx.t
    -> ('a, 'b, [< `Zero | `One ]) Caqti.Template.Request.t
    -> 'a
    -> 'b option Lwt.t

  val populate
    :  _ Ctx.t
    -> string
    -> string list
    -> 'a Caqti.Template.Row_type.t
    -> 'a list
    -> unit Lwt.t

  val transaction
    :  ?setup:(Caqti_lwt.connection -> (unit, Caqti.Error.t) Lwt_result.t) list
    -> ?cleanup:(Caqti_lwt.connection -> (unit, Caqti.Error.t) Lwt_result.t) list
    -> _ Ctx.t
    -> (Caqti_lwt.connection -> ('a, Caqti.Error.t) Lwt_result.t)
    -> 'a Lwt.t

  val connection_transaction
    :  Caqti_lwt.connection
    -> (unit -> ('a, Caqti.Error.t) Lwt_result.t)
    -> ('a, Caqti.Error.t) Lwt_result.t

  val transaction_iter
    :  _ Ctx.t
    -> (Caqti_lwt.connection -> (unit, Caqti.Error.t) Lwt_result.t) list
    -> unit Lwt.t
end

module Make (Db : Pools_sig.Sig) = struct
  module With_roles = Db

  let options = Db.options

  module Pool = struct
    let initialize = Db.Pool.initialize
    let add = Db.Pool.add
    let reset = Db.Pool.reset
    let drop = Db.Pool.drop
    let clear = Db.Pool.clear
    let find = Db.Pool.find
    let find_all = Db.Pool.find_all
    let fetch label = Db.Pool.fetch label
    let connect label = Db.Pool.connect label
    let ping label = Db.Pool.ping label
    let test = Db.Pool.test
    let disconnect ?error label = Db.Pool.disconnect ?error label
  end

  let label_ctx ?tags label = Db.label_ctx ?tags ~role label
  let connection_ctx ?tags label f = Db.connection_ctx ?tags ~role label f
  let transaction_ctx ?tags label f = Db.transaction_ctx ?tags ~role label f
  let with_transaction = Db.with_transaction
  let request caqti = Request.create ~needs caqti
  let query ctx f = Db.query ~needs ctx f
  let exec ctx caqti input = Db.exec ctx (request caqti) input
  let collect ctx caqti input = Db.collect ctx (request caqti) input
  let find ctx caqti input = Db.find ctx (request caqti) input
  let find_opt ctx caqti input = Db.find_opt ctx (request caqti) input

  let populate ctx table columns row_type rows =
    Db.populate ~needs ctx table columns row_type rows
  ;;

  let transaction ?setup ?cleanup ctx f = Db.transaction ?setup ?cleanup ~needs ctx f
  let connection_transaction = Db.connection_transaction
  let transaction_iter ctx fs = Db.transaction_iter ~needs ctx fs
end

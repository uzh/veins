(** Veins for one database user: no roles, no needs.

    For applications that connect with a single user and don't separate
    rights. Contexts have no role, statements are plain Caqti requests, and
    nothing takes [~role] or [~needs]:

    {[
    module Db = Veins_mariadb.Plain.Make (struct
        let database () =
          let url = Veins.Url.create (Sys.getenv "DATABASE_URL") in
          Veins.Database.create (Veins.Label.create "root") url
        ;;
      end)

    let find_name =
      {sql| SELECT name FROM users WHERE id = ? |sql}
      |> Caqti.Templater.(static T.(int -->? string))
    ;;

    let () =
      Db.Pool.initialize ();
      let root = Veins.Label.create "root" in
      Lwt_main.run
        (let%lwt name = Db.find_opt (Db.label_ctx root) find_name 1 in
         Db.transaction_ctx root (fun ctx ->
           Veins.Plain.Ctx.after_commit ctx (fun () -> print_endline "committed");
           Db.find_opt ctx find_name 2))
    ;;
    ]}

    Underneath these are the pools of {!Veins.Pools_sig.Sig}: every context is one
    of {!Veins.Role.owner}, connecting with the database's own URL, and
    every statement declares {!Veins.Need.none}. Everything else (held
    connections, transactions, reconnects, errors) behaves as described
    there.

    @canonical Veins.Plain *)

(** What the single user's contexts grant: everything. Only a type; it has
    no values. *)
type all

(** Database contexts without a role, see {!Veins.Ctx}. *)
module Ctx : sig
  type no_transaction = Ctx.no_transaction
  type transaction = Ctx.transaction

  (** A context of the single user: a label, a held connection or a
      transaction. Built by a pool ({!Sig}) only. *)
  type 'txn t = private ('txn, all) Ctx.t

  (** A context of either kind. *)
  type any = Any : 'maybe_txn t -> any [@@ocaml.unboxed]

  val txn : 'maybe_txn t -> 'maybe_txn Ctx.txn
  val is_transaction : _ t -> bool
  val label : _ t -> Entity.Label.t
  val tags : _ t -> Logs.Tag.set

  (** [after_commit ctx f] runs [f] right away unless [ctx] is a transaction;
      then [f] runs once it has committed, and is dropped on rollback. *)
  val after_commit : _ t -> (unit -> unit) -> unit

  (** Log tag carrying the label of the context. *)
  val label_tag : Entity.Label.t Logs.Tag.def

  (** The same context for code written with roles (e.g. a library whose
      functions state their needs): the single user is the owner, who grants
      whatever is asked for. Statements run on the result share [ctx]'s
      connection and transaction. *)
  val with_roles : 'maybe_txn t -> ('maybe_txn, _) Ctx.t
end

(** The interface of a {!Make} application: {!Veins.Pools_sig.Sig} without roles,
    logins and needs. *)
module type Sig = sig
  (** The pools underneath, with roles. For what is written against
      {!Veins.Pools_sig.Sig}, e.g. [Veins.Migration.Make (Db.With_roles)] (leave
      its [?role] out: the default is the owner). *)
  module With_roles : Pools_sig.Sig

  (** The options the pools were made with. *)
  val options : Pool_options.t

  (** {1 Pool lifecycle}

      As [Pools_sig.Sig.Pool], always for the database's own URL. *)

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

    (** The Caqti pool of the label. Connections taken from it directly are
        the driver's own: pass them through {!Veins.Connection.fixed}.

        @raise Veins.Error.Exn [Database_not_registered].
        @raise Veins.Error.Failed while a pool that lost its database waits to reconnect.
    *)
    val fetch
      :  Entity.Label.t
      -> (Caqti_lwt.connection, Caqti.Error.t) Caqti_lwt_unix.Pool.t Lwt.t

    val connect : Entity.Label.t -> (unit, Error.t) result
    val ping : Entity.Label.t -> (unit, Error.t) Lwt_result.t

    (** [use label f] runs [f] on a {!Veins.Connection.fixed} connection of
        the label and returns its result as it is, for code that expects
        Caqti's results instead of veins' exceptions (e.g. a framework
        sharing the pools). Lost connections drop the pool as for every
        statement; see [Pools_sig.Sig.Pool.use].

        @raise Veins.Error.Exn [Database_not_registered]. *)
    val use
      :  Entity.Label.t
      -> (Caqti_lwt.connection -> ('a, Caqti.Error.t) Lwt_result.t)
      -> ('a, Caqti.Error.t) Lwt_result.t

    val test : Entity.Database.t -> (unit, Error.t) Lwt_result.t
    val disconnect : ?error:Caqti.Error.t -> Entity.Label.t -> unit
  end

  (** {1 Contexts} *)

  (** A context taking a fresh connection from the pool for every statement. *)
  val label_ctx : ?tags:Logs.Tag.set -> Entity.Label.t -> Ctx.no_transaction Ctx.t

  (** [connection_ctx label f] runs [f] with one connection held for all its
      statements. *)
  val connection_ctx
    :  ?tags:Logs.Tag.set
    -> Entity.Label.t
    -> (Ctx.no_transaction Ctx.t -> 'a Lwt.t)
    -> 'a Lwt.t

  (** [transaction_ctx label f] runs [f] in a transaction on a new
      connection: it commits when [f] returns and rolls back when it raises. *)
  val transaction_ctx
    :  ?tags:Logs.Tag.set
    -> Entity.Label.t
    -> (Ctx.transaction Ctx.t -> 'a Lwt.t)
    -> 'a Lwt.t

  (** [with_transaction ctx f] runs [f] in a transaction on [ctx], joining
      it when it is a transaction already. *)
  val with_transaction : _ Ctx.t -> (Ctx.transaction Ctx.t -> 'a Lwt.t) -> 'a Lwt.t

  (** {1 Statements} *)

  (** [query ctx f] runs [f] on a connection of [ctx], a
      {!Veins.Connection.fixed} one. *)
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

  (** @raise Veins.Error.Failed unless the statement returns exactly one row. *)
  val find : _ Ctx.t -> ('a, 'b, [< `One ]) Caqti.Template.Request.t -> 'a -> 'b Lwt.t

  val find_opt
    :  _ Ctx.t
    -> ('a, 'b, [< `Zero | `One ]) Caqti.Template.Request.t
    -> 'a
    -> 'b option Lwt.t

  (** [populate ctx table columns row_type rows] bulk-inserts [rows]: all of
      them or, when one fails, none. [table] and [columns] go into the SQL as
      they are: never build them from user input. *)
  val populate
    :  _ Ctx.t
    -> string
    -> string list
    -> 'a Caqti.Template.Row_type.t
    -> 'a list
    -> unit Lwt.t

  (** [transaction ctx f] runs [f] on one connection inside a transaction,
      joining [ctx]'s transaction when there is one. [f] gets the connection
      itself: run its statements on that, not on [ctx]. *)
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

  (** {!transaction} running [fs] in order. *)
  val transaction_iter
    :  _ Ctx.t
    -> (Caqti_lwt.connection -> (unit, Caqti.Error.t) Lwt_result.t) list
    -> unit Lwt.t
end

(** The pools of [Db] without roles. The driver libraries apply it for you:
    [Veins_mariadb.Plain.Make], [Veins_postgresql.Plain.Make], and with a
    pool size and {!Veins.Pool_options} of your own their
    [Plain.Make_with_options]. Over other pools:

    {[
    module Db = Veins.Plain.Make (Veins.Pools.Make_with_options (Config) (Options))
    ]} *)
module Make : functor (Db : Pools_sig.Sig) -> Sig with module With_roles = Db

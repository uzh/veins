(** Module-type signatures for the Veins pool functor.

    Application code instantiates a pool by applying {!Pools.Make} to a
    module satisfying {!ConfigSig}. The resulting module satisfies {!Sig}.

    @canonical Veins.Pools_sig *)

(** Configuration required to instantiate a connection pool. *)
module type ConfigSig = sig
  (** The primary database, registered by [Pool.initialize]. *)
  val database : Entity.Database.t

  (** Maximum number of open connections Caqti keeps per pool (one pool per
      label for the owner, plus one per login with a URL of its own). *)
  val database_pool_size : int

  (** Hint for the initial hashtable capacity. *)
  val expected_databases : int

  (** SQL dialect. Prefer [Veins_mariadb.Dialect] / [Veins_postgresql.Dialect]:
      they also recognise the driver's "connection lost" errors. *)
  module Dialect : Dialect.Sig
end

(** The interface of a {!Pools.Make} application.

    Statements run on a context ({!Ctx.t}): a label (fresh connection per
    statement), a held connection, or a transaction. Every helper raises
    {!Error.Failed} when the database rejects a statement, and
    {!Error.Exn} for errors veins detects itself and for
    [Error.Permission_denied].

    {b Roles.} Every context names its role ({!Veins.Role}), and connects
    as the role's login. A statement only runs on a context whose role type
    grants everything it needs ({!Request.t}, {!Veins.Need}): the compiler
    checks this, nothing is checked at runtime. *)
module type Sig = sig
  module Config : ConfigSig

  (** {1 Pool lifecycle} *)

  module Pool : sig
    (** Register the primary database from [Config] and [additional_pools].
        Labels already registered are skipped. Connections are opened lazily,
        on first use. *)
    val initialize : ?additional_pools:Entity.Database.t list -> unit -> unit

    (** Register a database. Logs a warning and does nothing if its label is
        registered already. With [~required:true], failing to connect raises
        instead of marking the pool as failed. *)
    val add : ?required:bool -> Entity.Database.t -> unit

    (** Replace the registration of [database]'s label (e.g. new credentials);
        its old connections are closed in the background. *)
    val reset : ?required:bool -> Entity.Database.t -> unit

    (** Remove a database and close its connections in the background. Safe to
        call for unknown labels. *)
    val drop : Entity.Label.t -> unit

    (** Remove every database and close all connections in the background. *)
    val clear : unit -> unit

    (** The database registered under the label. *)
    val find : Entity.Label.t -> Entity.Database.t option

    (** All registered databases, optionally filtered to [allowed_status] and
        without the [exclude]d labels. *)
    val find_all
      :  ?allowed_status:Entity.Status.t list
      -> ?exclude:Entity.Label.t list
      -> unit
      -> Entity.Database.t list

    (** The Caqti pool [login] (default {!Veins.Login.owner}) connects with,
        connecting or reconnecting when needed. After [retries] failed
        reconnects the call raises, and the next call tries again.

        @raise Error.Exn [Database_not_registered].
        @raise Error.Failed when connecting fails. *)
    val fetch
      :  ?retries:int
      -> ?login:Entity.Login.t
      -> Entity.Label.t
      -> (Caqti_lwt.connection, Caqti.Error.t) Caqti_lwt_unix.Pool.t Lwt.t

    (** Try to open the pool [login] (default {!Veins.Login.owner}) connects
        with, without raising. *)
    val connect : ?login:Entity.Login.t -> Entity.Label.t -> (unit, Error.t) result

    (** Close the connections of the label's pools (only the one [login]
        connects with, with [~login]) in the background and mark them
        closed, or failed with [~error]; the next statement reconnects. *)
    val disconnect
      :  ?error:Caqti.Error.t
      -> ?login:Entity.Login.t
      -> Entity.Label.t
      -> unit
  end

  (** {1 Contexts} *)

  (** A context taking a fresh connection from the pool for every statement. *)
  val label_ctx
    :  ?tags:Logs.Tag.set
    -> role:'g Entity.Role.t
    -> Entity.Label.t
    -> (Ctx.no_transaction, 'g) Ctx.t

  (** [connection_ctx ~role label f] runs [f] with one connection held for
      all its statements (session state like [SET] stays). Statements on it
      run one at a time. *)
  val connection_ctx
    :  ?tags:Logs.Tag.set
    -> role:'g Entity.Role.t
    -> Entity.Label.t
    -> ((Ctx.no_transaction, 'g) Ctx.t -> 'a Lwt.t)
    -> 'a Lwt.t

  (** [transaction_ctx ~role label f] runs [f] in a transaction on a new
      connection: it commits when [f] returns and rolls back when it raises.
      Hooks registered with {!Ctx.after_commit} run after the commit. *)
  val transaction_ctx
    :  ?tags:Logs.Tag.set
    -> role:'g Entity.Role.t
    -> Entity.Label.t
    -> ((Ctx.transaction, 'g) Ctx.t -> 'a Lwt.t)
    -> 'a Lwt.t

  (** [with_transaction ctx f] runs [f] in a transaction on [ctx]: it joins
      [ctx] when it is a transaction already (so [f]'s statements commit or
      roll back with it), starts one on a held connection, and behaves like
      {!transaction_ctx} for a label context. Always runs as [ctx]'s role. *)
  val with_transaction
    :  ('maybe_txn, 'g) Ctx.t
    -> ((Ctx.transaction, 'g) Ctx.t -> 'a Lwt.t)
    -> 'a Lwt.t

  (** {1 Statements}

      Each statement's needs must be granted by the context's role:
      [exec ctx request] type-checks only if ['g] of [ctx] has every tag of
      [request]'s needs. *)

  (** [query ~needs ctx f] runs [f] on a connection of [ctx]. [needs] are the
      needs of the statements [f] runs, which the compiler can't see. *)
  val query
    :  needs:'g Entity.Need.t
    -> (_, 'g) Ctx.t
    -> (Caqti_lwt.connection -> ('a, Caqti.Error.t) Lwt_result.t)
    -> 'a Lwt.t

  val exec : (_, 'g) Ctx.t -> ('a, unit, [< `Zero ], 'g) Request.t -> 'a -> unit Lwt.t

  val collect
    :  (_, 'g) Ctx.t
    -> ('a, 'b, [< `Zero | `One | `Many ], 'g) Request.t
    -> 'a
    -> 'b list Lwt.t

  (** @raise Error.Failed unless the statement returns exactly one row. *)
  val find : (_, 'g) Ctx.t -> ('a, 'b, [< `One ], 'g) Request.t -> 'a -> 'b Lwt.t

  val find_opt
    :  (_, 'g) Ctx.t
    -> ('a, 'b, [< `Zero | `One ], 'g) Request.t
    -> 'a
    -> 'b option Lwt.t

  (** [populate ~needs ctx table columns row_type rows] bulk-inserts [rows]. *)
  val populate
    :  needs:'g Entity.Need.t
    -> (_, 'g) Ctx.t
    -> string
    -> string list
    -> 'a Caqti.Template.Row_type.t
    -> 'a list
    -> unit Lwt.t

  (** [transaction ~needs ctx f] runs [f] on one connection inside a
      transaction, joining [ctx]'s transaction when there is one.

      @param setup statements run after [BEGIN], before [f]
      @param cleanup statements run after [f], before [COMMIT] *)
  val transaction
    :  ?setup:(Caqti_lwt.connection -> (unit, Caqti.Error.t) Lwt_result.t) list
    -> ?cleanup:(Caqti_lwt.connection -> (unit, Caqti.Error.t) Lwt_result.t) list
    -> needs:'g Entity.Need.t
    -> (_, 'g) Ctx.t
    -> (Caqti_lwt.connection -> ('a, Caqti.Error.t) Lwt_result.t)
    -> 'a Lwt.t

  (** {!transaction} running [fs] in order. *)
  val transaction_iter
    :  needs:'g Entity.Need.t
    -> (_, 'g) Ctx.t
    -> (Caqti_lwt.connection -> (unit, Caqti.Error.t) Lwt_result.t) list
    -> unit Lwt.t
end

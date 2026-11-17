(** Module-type signatures for the Veins pool functor.

    Application code instantiates a pool by applying {!Veins.Pools.Make} to a
    module satisfying {!ConfigSig}. The resulting module satisfies {!Sig}.

    @canonical Veins.Pools_sig *)

(** Configuration required to instantiate a connection pool. *)
module type ConfigSig = sig
  (** The primary database, registered by [Pool.initialize], which calls
      this every time it runs. Nothing calls it when the module is made, so
      it may read a configuration that is loaded later, at startup (an
      environment file, a test setup). *)
  val database : unit -> Entity.Database.t

  (** Maximum number of open connections Caqti keeps per pool (one pool per
      label for the owner, plus one per login with a URL of its own). A
      process may so open up to [database_pool_size] × pools connections:
      mind the server's connection limit. Idle ones are closed after
      [Pool_options.max_idle_age]. *)
  val database_pool_size : int

  (** Hint for the initial hashtable capacity. *)
  val expected_databases : int

  (** How to read the driver's errors. Prefer [Veins_mariadb.Driver] /
      [Veins_postgresql.Driver], which recognise lost connections and missing
      privileges; {!Veins.Driver.Generic} only knows connect errors. The SQL veins
      sends follows each connection's dialect, see {!Veins.Dialect}. *)
  module Driver : Driver.Sig
end

(** The tuning of {!Veins.Pools.Make_with_options}. *)
module type OptionsSig = sig
  val options : Pool_options.t
end

(** The interface of a {!Veins.Pools.Make} application.

    Statements run on a context ({!Veins.Ctx.t}): a label (fresh connection per
    statement), a held connection, or a transaction. Every helper raises
    {!Veins.Error.Failed} when the database rejects a statement, and
    {!Veins.Error.Exn} for errors veins detects itself and for
    [Error.Permission_denied].

    {b Roles.} Every context names its role ({!Veins.Role}), and connects
    as the role's login. A statement only runs on a context whose role type
    grants everything it needs ({!Veins.Request.t}, {!Veins.Need}): the compiler
    checks this, nothing is checked at runtime.

    {b Lost databases.} A connection error drops the pool. The next
    statement reconnects; if that fails too, statements fail right away with
    the last connection error for a growing while
    ([Pool_options.reconnect_backoff]), then a single statement tries again,
    so an unreachable database doesn't get a connection attempt per
    statement. *)
module type Sig = sig
  module Config : ConfigSig

  (** The options the pools were made with. *)
  val options : Pool_options.t

  (** {1 Pool lifecycle} *)

  module Pool : sig
    (** Register the primary database ([Config.database ()]) and
        [additional_pools].
        Labels already registered are skipped. Connections are opened lazily,
        on first use. *)
    val initialize : ?additional_pools:Entity.Database.t list -> unit -> unit

    (** Register a database. Logs a warning and does nothing if its label is
        registered already. Nothing connects yet: with [~required:true], a
        URL no pool can be set up for (e.g. no driver for its scheme) raises
        on first use instead of marking the pool as failed. Use {!ping} to
        learn whether the database answers. *)
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
        set up anew when it was closed or failed. Caqti connects lazily, so
        this doesn't tell whether the database answers. [retries] is ignored
        and only kept for compatibility: reconnects are paced by
        [Pool_options.reconnect_backoff].

        Connections taken from the pool directly are the driver's own:
        pass them through {!Veins.Connection.fixed}.

        @raise Veins.Error.Exn [Database_not_registered], [Login_not_configured].
        @raise Veins.Error.Failed while a pool that lost its database waits to reconnect.
    *)
    val fetch
      :  ?retries:int
      -> ?login:Entity.Login.t
      -> Entity.Label.t
      -> (Caqti_lwt.connection, Caqti.Error.t) Caqti_lwt_unix.Pool.t Lwt.t

    (** Set up the pool [login] (default {!Veins.Login.owner}) connects
        with, without raising. [Ok ()] means the pool exists, not that the
        database answers (see {!ping}); a pool that lost its database gives
        [Error] until a statement or {!disconnect} resets it. *)
    val connect : ?login:Entity.Login.t -> Entity.Label.t -> (unit, Error.t) result

    (** Take a connection of the pool [login] (default {!Veins.Login.owner})
        connects with, connecting if there is none: [Ok ()] if the database
        answered. Counts as a statement for the reconnect backoff. *)
    val ping : ?login:Entity.Login.t -> Entity.Label.t -> (unit, Error.t) Lwt_result.t

    (** [use label f] runs [f] on a connection of the pool [login] (default
        {!Veins.Login.owner}) connects with, for code that expects Caqti's
        results instead of veins' exceptions, e.g. a framework sharing the
        pools. It is a statement, not a context: no role, nothing checked.

        [f] gets a {!Veins.Connection.fixed} connection. Its [Error] is
        returned as it is; a lost connection drops the pool, and the next
        statement reconnects, as for every statement. A pool waiting to
        reconnect, or one that gives no connection within
        [Pool_options.acquire_timeout], gives [Error] too, a
        [`Connect_failed] for the latter. Errors are not reported to
        [Pool_options.on_failure], and exceptions of [f] pass through.

        @raise Veins.Error.Exn
          [Database_not_registered],
          [Login_not_configured]: setup errors, not the database's. *)
    val use
      :  ?login:Entity.Login.t
      -> Entity.Label.t
      -> (Caqti_lwt.connection -> ('a, Caqti.Error.t) Lwt_result.t)
      -> ('a, Caqti.Error.t) Lwt_result.t

    (** [test database] connects once to every URL of [database] (the
        owner's, then each login's) with {!Veins.Connection.test}, the way the
        pools do: same driver, PostgreSQL's default [connect_timeout], the
        session settings of {!options}. [Ok ()] if all of them answered,
        otherwise the first failure, an [Error.Connection_failed] whose
        message shows the URL without its password. No pool is touched, and
        [database] needs not be registered: it serves to check a database
        before {!add}.

        When [database] is the one registered under its label (same URLs),
        the outcome shows in the registered status, as {!find} and
        {!find_all} tell it: a failure turns [Active] into
        [ConnectionIssue], a success turns [ConnectionIssue] back into
        [Active]. Other statuses stay, and the pools keep reconnecting on
        their own either way. *)
    val test : Entity.Database.t -> (unit, Error.t) Lwt_result.t

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
      run one at a time, and without the check a label context makes before
      every statement (on MariaDB a ping, i.e. a round trip): prefer it for
      code running several statements.

      Don't share the context between concurrent threads that use
      transactions: only statements are serialised, so a statement of one
      thread joins the transaction another thread has open on the
      connection, and commits or rolls back with it. *)
  val connection_ctx
    :  ?tags:Logs.Tag.set
    -> role:'g Entity.Role.t
    -> Entity.Label.t
    -> ((Ctx.no_transaction, 'g) Ctx.t -> 'a Lwt.t)
    -> 'a Lwt.t

  (** [transaction_ctx ~role label f] runs [f] in a transaction on a new
      connection: it commits when [f] returns and rolls back when it raises.
      Hooks registered with {!Veins.Ctx.after_commit} run after the commit. *)
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
      needs of the statements [f] runs, which the compiler can't see.

      The connection, like every one veins passes to a function, is a
      {!Veins.Connection.fixed} one: its [rollback], [with_transaction] and
      [populate] are safe to use. *)
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

  (** @raise Veins.Error.Failed unless the statement returns exactly one row. *)
  val find : (_, 'g) Ctx.t -> ('a, 'b, [< `One ], 'g) Request.t -> 'a -> 'b Lwt.t

  val find_opt
    :  (_, 'g) Ctx.t
    -> ('a, 'b, [< `Zero | `One ], 'g) Request.t
    -> 'a
    -> 'b option Lwt.t

  (** [populate ~needs ctx table columns row_type rows] bulk-inserts [rows]:
      all of them or, when one fails, none. In a transaction context the
      rows join it. [table] and [columns] go into the SQL as they are: never
      build them from user input. *)
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

      [f] gets the connection itself: run its statements on that, not on
      [ctx], which waits for [f] to return when it holds the connection.

      @param setup statements run after [BEGIN], before [f]
      @param cleanup statements run after [f], before [COMMIT] *)
  val transaction
    :  ?setup:(Caqti_lwt.connection -> (unit, Caqti.Error.t) Lwt_result.t) list
    -> ?cleanup:(Caqti_lwt.connection -> (unit, Caqti.Error.t) Lwt_result.t) list
    -> needs:'g Entity.Need.t
    -> (_, 'g) Ctx.t
    -> (Caqti_lwt.connection -> ('a, Caqti.Error.t) Lwt_result.t)
    -> 'a Lwt.t

  (** [connection_transaction connection f] runs [f] in a transaction on a raw
      [connection] (e.g. inside {!query}): commits on [Ok], rolls back on
      [Error] and on exceptions (re-raised). It is [with_transaction] of the
      {!Veins.Connection.fixed} connection, for connections that may not come from
      veins. *)
  val connection_transaction
    :  Caqti_lwt.connection
    -> (unit -> ('a, Caqti.Error.t) Lwt_result.t)
    -> ('a, Caqti.Error.t) Lwt_result.t

  (** {!transaction} running [fs] in order. *)
  val transaction_iter
    :  needs:'g Entity.Need.t
    -> (_, 'g) Ctx.t
    -> (Caqti_lwt.connection -> (unit, Caqti.Error.t) Lwt_result.t) list
    -> unit Lwt.t
end

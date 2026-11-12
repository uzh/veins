(** Module-type signatures for the Veins pool functor.

    Application code instantiates a pool by applying {!Pools.Make} to a
    module satisfying {!ConfigSig}. The resulting module satisfies {!Sig}.

    @canonical Veins.Pools_sig *)

(** Configuration required to instantiate a connection pool. *)
module type ConfigSig = sig
  (** The primary database, registered by [Pool.initialize]. *)
  val database : Entity.Database.t

  (** Maximum number of open connections Caqti keeps per pool (one pool per
      label, or per label and role). *)
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
    {!Error.Failed} when the database rejects a statement and {!Error.Exn} for
    errors veins detects itself, e.g. a missing capability.

    {b Roles.} On a database with one URL per role ([Multiple]) every context
    must name a role ([Error.Role_required] otherwise), and every statement's
    capabilities must be within that role's ([Error.Insufficient_capabilities]
    otherwise, raised before the statement is sent). A single-URL database
    ([Main]) has every capability. *)
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

    (** The Caqti pool for the label (and role), connecting or reconnecting
        when needed. After [retries] failed reconnects the call raises, and
        the next call tries again.

        @raise Error.Exn
          [Database_not_registered], [Role_required] or
          [Role_not_configured].
        @raise Error.Failed when connecting fails. *)
    val fetch
      :  ?retries:int
      -> ?role:Entity.Role.t
      -> Entity.Label.t
      -> (Caqti_lwt.connection, Caqti_error.t) Caqti_lwt_unix.Pool.t Lwt.t

    (** Try to open the pool for the label (and role) without raising. *)
    val connect : ?role:Entity.Role.t -> Entity.Label.t -> (unit, Error.t) result

    (** Close the connections of the label's pools (one role's, with [~role])
        in the background and mark them closed, or failed with [~error]; the
        next statement reconnects. *)
    val disconnect : ?error:Caqti_error.t -> ?role:Entity.Role.t -> Entity.Label.t -> unit
  end

  (** {1 Contexts} *)

  (** A context taking a fresh connection from the pool for every statement. *)
  val label_ctx
    :  ?tags:Logs.Tag.set
    -> ?role:Entity.Role.t
    -> Entity.Label.t
    -> Ctx.no_transaction Ctx.t

  (** [connection_ctx label f] runs [f] with one connection held for all its
      statements (session state like [SET] stays). Statements on it run one
      at a time. *)
  val connection_ctx
    :  ?tags:Logs.Tag.set
    -> ?role:Entity.Role.t
    -> Entity.Label.t
    -> (Ctx.no_transaction Ctx.t -> 'a Lwt.t)
    -> 'a Lwt.t

  (** [transaction_ctx label f] runs [f] in a transaction on a new connection:
      it commits when [f] returns and rolls back when it raises. Hooks
      registered with {!Ctx.after_commit} run after the commit. *)
  val transaction_ctx
    :  ?tags:Logs.Tag.set
    -> ?role:Entity.Role.t
    -> Entity.Label.t
    -> (Ctx.transaction Ctx.t -> 'a Lwt.t)
    -> 'a Lwt.t

  (** [with_transaction ctx f] runs [f] in a transaction on [ctx]: it joins
      [ctx] when it is a transaction already (so [f]'s statements commit or
      roll back with it), starts one on a held connection, and behaves like
      {!transaction_ctx} for a label context. Always runs as [ctx]'s role. *)
  val with_transaction : _ Ctx.t -> (Ctx.transaction Ctx.t -> 'a Lwt.t) -> 'a Lwt.t

  (** {1 Statements} *)

  (** [query ~needs ctx f] runs [f] on a connection of [ctx]. [needs] is
      checked once against [ctx]'s role before [f] runs; the statements
      inside [f] are trusted to stay within it. *)
  val query
    :  needs:Entity.Capability.t list
    -> _ Ctx.t
    -> (Caqti_lwt.connection -> ('a, Caqti_error.t) Lwt_result.t)
    -> 'a Lwt.t

  val exec : _ Ctx.t -> ('a, unit, [< `Zero ]) Request.t -> 'a -> unit Lwt.t

  val collect
    :  _ Ctx.t
    -> ('a, 'b, [< `Zero | `One | `Many ]) Request.t
    -> 'a
    -> 'b list Lwt.t

  (** @raise Error.Failed unless the statement returns exactly one row. *)
  val find : _ Ctx.t -> ('a, 'b, [< `One ]) Request.t -> 'a -> 'b Lwt.t

  val find_opt : _ Ctx.t -> ('a, 'b, [< `Zero | `One ]) Request.t -> 'a -> 'b option Lwt.t

  (** [populate ~needs ctx table columns row_type rows] bulk-inserts [rows]. *)
  val populate
    :  needs:Entity.Capability.t list
    -> _ Ctx.t
    -> string
    -> string list
    -> 'a Caqti_type.t
    -> 'a list
    -> unit Lwt.t

  (** [transaction ~needs ctx f] runs [f] on one connection inside a
      transaction, joining [ctx]'s transaction when there is one.

      @param setup statements run after [BEGIN], before [f]
      @param cleanup statements run after [f], before [COMMIT] *)
  val transaction
    :  ?setup:(Caqti_lwt.connection -> (unit, Caqti_error.t) Lwt_result.t) list
    -> ?cleanup:(Caqti_lwt.connection -> (unit, Caqti_error.t) Lwt_result.t) list
    -> needs:Entity.Capability.t list
    -> _ Ctx.t
    -> (Caqti_lwt.connection -> ('a, Caqti_error.t) Lwt_result.t)
    -> 'a Lwt.t

  (** {!transaction} running [fs] in order. *)
  val transaction_iter
    :  needs:Entity.Capability.t list
    -> _ Ctx.t
    -> (Caqti_lwt.connection -> (unit, Caqti_error.t) Lwt_result.t) list
    -> unit Lwt.t
end

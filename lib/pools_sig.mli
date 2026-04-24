(** Module-type signatures for the Vena pool functor.

    Application code instantiates a pool by applying {!Pools.Make} to a
    module satisfying {!ConfigSig}.  The resulting module satisfies {!Sig}. *)

(** Configuration required to instantiate a connection pool. *)
module type ConfigSig = sig
  (** The primary database for this pool instance.
      Its label becomes the canonical name used throughout the pool and serves
      as the default target for query helpers. *)
  val database : Entity.Database.t

  (** Maximum number of open connections Caqti will maintain per pool.
      Tune this to match the connection limit of the database server. *)
  val database_pool_size : int

  (** Hint for the initial hashtable capacity.  Set this to the number of
      additional databases you expect to register via [Pool.add] beyond the
      primary one (default: 5). *)
  val expected_databases : int

  (** SQL dialect for DDL/DML differences between MariaDB and PostgreSQL.
      Use {!Dialect.Mariadb} or {!Dialect.Postgresql}. *)
  module Dialect : Dialect.Sig
end

(** The interface exposed by a {!Pools.Make} functor application.

    All query helpers raise {!Error.Exn} on error rather than returning a
    [result] value, so callers can use plain [let%lwt] bindings.  Wrap
    operations that need an explicit error boundary in {!transaction}. *)
module type Sig = sig
  (** The configuration this pool was instantiated with. *)
  module Config : ConfigSig

  (** {1 Pool lifecycle} *)

  module Pool : sig
    (** Register the primary database from [Config] and any
        [additional_pools] so they are available via [fetch].
        Idempotent: labels already present in the cache are skipped. *)
    val initialize : ?additional_pools:Entity.Database.t list -> unit -> unit

    (** Register a new pool entry.
        Logs a warning and is a no-op if the label is already registered. *)
    val add : ?required:bool -> Entity.Database.t -> unit

    (** Drain the existing pool for [database.label] and open a fresh one.
        Useful after a credential rotation. *)
    val reset : ?required:bool -> Entity.Database.t -> unit Lwt.t

    (** Drain and remove a pool from the cache.  Safe to call even if the
        label is not registered (logged as info and ignored). *)
    val drop : Entity.Label.t -> unit Lwt.t

    (** Drain every pool and clear the cache.  Primarily useful in test
        teardown. *)
    val clear : unit -> unit

    (** Borrow the raw Caqti pool for [label], reconnecting automatically
        when the connection is in a [Close] or [Fail] state.

        @raise Error.Exn (Database_not_registered _)  if [label] was never
               added.
        @raise Error.Exn (Connection_failed _)         after all [retries]
               are exhausted. *)
    val fetch
      :  ?retries:int
      -> Entity.Label.t
      -> (Caqti_lwt.connection, Caqti_error.t) Caqti_lwt_unix.Pool.t Lwt.t

    (** Attempt to ensure an open connection exists for [label].
        Returns [Ok ()] or [Error _] without raising; safe to call from
        synchronous startup code. *)
    val connect : Entity.Label.t -> (unit, Error.t) result

    (** Drain the pool for [label] and mark it [Close] so the next [fetch]
        triggers a reconnect.  The entry remains in the cache. *)
    val disconnect : Entity.Label.t -> unit Lwt.t

    (** Drop [label], then register [database] under the same position in
        the cache.  Use when the connection parameters for a pool have
        changed. *)
    val reset_label
      :  ?required:bool
      -> Entity.Label.t
      -> Entity.Database.t
      -> unit Lwt.t

    (** All databases currently registered in the cache, optionally
        filtered to [allowed_status] and with [exclude]d labels removed. *)
    val find_all
      :  ?allowed_status:Entity.Status.t list
      -> ?exclude:Entity.Label.t list
      -> unit
      -> Entity.Database.t list

    (** Raise a human-readable {!Error.Exn} for a Caqti error.
        Also marks the affected pool as [Fail] so the next [fetch] will
        attempt to reconnect. *)
    val raise_caqti_error
      :  Entity.Label.t
      -> ('a, Caqti_error.t) Lwt_result.t
      -> 'a Lwt.t
  end

  (** {1 Query helpers}

      Each helper accepts an {!Entity.Label.t} identifying which connection
      pool to borrow from, keeping the raw connection out of call sites. *)

  (** Run [f] with a borrowed connection from [label]'s pool.
      Errors returned by [f] are converted to {!Error.Exn} via
      {!Pool.raise_caqti_error}. *)
  val query
    :  Entity.Label.t
    -> (Caqti_lwt.connection -> ('a, Caqti_error.t) Lwt_result.t)
    -> 'a Lwt.t

  (** Execute a statement that produces no result rows. *)
  val exec
    :  Entity.Label.t
    -> ('a, unit, [ `Zero ]) Caqti_request.t
    -> 'a
    -> unit Lwt.t

  (** Collect all result rows into a list. *)
  val collect
    :  Entity.Label.t
    -> ('a, 'b, [< `Zero | `One | `Many ]) Caqti_request.t
    -> 'a
    -> 'b list Lwt.t

  (** Return exactly one row.
      @raise Error.Exn if the query returns zero or more than one row. *)
  val find
    :  Entity.Label.t
    -> ('a, 'b, [< `One ]) Caqti_request.t
    -> 'a
    -> 'b Lwt.t

  (** Return at most one row, or [None] if the query returns no rows. *)
  val find_opt
    :  Entity.Label.t
    -> ('a, 'b, [< `Zero | `One ]) Caqti_request.t
    -> 'a
    -> 'b option Lwt.t

  (** Bulk-insert [rows] into [table].
      [column_names] must match the arity of [param_type].
      Empty [rows] is a no-op. *)
  val populate
    :  Entity.Label.t
    -> string
    -> string list
    -> 'a Caqti_type.t
    -> 'a list
    -> unit Lwt.t

  (** {1 Transactions}

      Each function borrows a single connection for the lifetime of the
      transaction.  On any exception the transaction is rolled back and
      {!Error.Exn} is re-raised. *)

  (** Run [f] inside a [BEGIN] / [COMMIT] block.

      @param setup   List of statements run after [BEGIN] but before [f]
                     (e.g. [SET TRANSACTION ISOLATION LEVEL …]).
      @param cleanup List of statements run after [f] but before [COMMIT]. *)
  val transaction
    :  ?setup:(Caqti_lwt.connection -> (unit, Caqti_error.t) Lwt_result.t) list
    -> ?cleanup:(Caqti_lwt.connection -> (unit, Caqti_error.t) Lwt_result.t) list
    -> Entity.Label.t
    -> (Caqti_lwt.connection -> ('a, Caqti_error.t) Lwt_result.t)
    -> 'a Lwt.t

  (** Run a list of [queries] inside a single transaction.
      Equivalent to calling {!transaction} with a combined function. *)
  val transaction_iter
    :  Entity.Label.t
    -> (Caqti_lwt.connection -> (unit, Caqti_error.t) Lwt_result.t) list
    -> unit Lwt.t
end

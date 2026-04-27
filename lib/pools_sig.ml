(** Module-type signatures for the Veins pool functor.

    Application code creates a concrete pool by applying [Pools.Make] to a
    module satisfying {!ConfigSig}. *)

(** Configuration required to instantiate a connection pool. *)
module type ConfigSig = sig
  (** The primary database for this pool instance (its label and URL). *)
  val database : Entity.Database.t

  (** Maximum number of open connections per pool (default: 10). *)
  val database_pool_size : int

  (** Hint for the initial hashtable capacity: how many databases (pools) are
      expected to be registered in this instance (default: 5). *)
  val expected_databases : int

  (** SQL dialect for DDL/DML differences between MariaDB and PostgreSQL. *)
  module Dialect : Dialect.Sig
end

(** The interface exposed by a [Pools.Make] functor application.

    All query helpers raise [Error.Exn] on error instead of returning
    [result] values, so callers can use plain [let%lwt] bindings.  Use
    [transaction] when you need a [Lwt_result.t] boundary. *)
module type Sig = sig
  module Config : ConfigSig

  (** {1 Pool lifecycle} *)

  module Pool : sig
    (** Register the primary database and any [additional_pools] so they are
        available for [fetch].  Idempotent: already-registered labels are
        skipped. *)
    val initialize : ?additional_pools:Entity.Database.t list -> unit -> unit

    (** Register a new pool.  Logs a warning and skips if the label already
        exists. *)
    val add : ?required:bool -> Entity.Database.t -> unit

    (** Drain and reconnect an existing pool.  Useful after a credential
        rotation. *)
    val reset : ?required:bool -> Entity.Database.t -> unit Lwt.t

    (** Drain and remove a pool from the cache. *)
    val drop : Entity.Label.t -> unit Lwt.t

    (** Clear every pool from the cache (useful in test teardown). *)
    val clear : unit -> unit

    (** Borrow the raw Caqti pool for [label].  Reconnects automatically when
        the connection is in a [Close] or [Fail] state.

        @raise Error.Exn Database_not_registered  if the label was never added.
        @raise Error.Exn Connection_failed         after all retries are exhausted. *)
    val fetch
      :  ?retries:int
      -> Entity.Label.t
      -> (Caqti_lwt.connection, Caqti_error.t) Caqti_lwt_unix.Pool.t Lwt.t

    (** [connect label] attempts to ensure an open connection exists.
        Returns [Ok ()] or [Error _] without raising. *)
    val connect : Entity.Label.t -> (unit, Error.t) result

    (** Disconnect (drain + mark closed) a pool.  The pool remains in the
        cache so the next [fetch] will reconnect. *)
    val disconnect : Entity.Label.t -> unit Lwt.t

    (** Disconnect then recreate a pool entry with fresh connection params. *)
    val reset_label
      :  ?required:bool
      -> Entity.Label.t
      -> Entity.Database.t
      -> unit Lwt.t

    (** All registered pool entries, optionally filtered by status. *)
    val find_all
      :  ?allowed_status:Entity.Status.t list
      -> ?exclude:Entity.Label.t list
      -> unit
      -> Entity.Database.t list

    (** Raise a human-readable [Error.Exn] for a Caqti error, also
        disconnecting the affected pool so it can reconnect on next use. *)
    val raise_caqti_error
      :  Entity.Label.t
      -> ('a, Caqti_error.t) Lwt_result.t
      -> 'a Lwt.t
  end

  (** {1 Query helpers}

      All helpers accept a {!Entity.Label.t} that identifies which connection
      pool to use, removing the connection parameter from every call site. *)

  (** Run [f] with a borrowed connection from [label]'s pool. *)
  val query
    :  Entity.Label.t
    -> (Caqti_lwt.connection -> ('a, Caqti_error.t) Lwt_result.t)
    -> 'a Lwt.t

  (** Execute a statement with no result rows. *)
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

  (** Return exactly one row; raise if the query returns zero or more than
      one row. *)
  val find
    :  Entity.Label.t
    -> ('a, 'b, [< `One ]) Caqti_request.t
    -> 'a
    -> 'b Lwt.t

  (** Return at most one row, or [None]. *)
  val find_opt
    :  Entity.Label.t
    -> ('a, 'b, [< `Zero | `One ]) Caqti_request.t
    -> 'a
    -> 'b option Lwt.t

  (** Insert [rows] into [table] using [column_names] as column list.
      Each element of [rows] must match [param_type]. *)
  val populate
    :  Entity.Label.t
    -> string
    -> string list
    -> 'a Caqti_type.t
    -> 'a list
    -> unit Lwt.t

  (** {1 Transactions}

      Transactions run inside a single connection borrowed from the pool.
      On any exception the transaction is rolled back; [Error.Exn] is
      re-raised after rollback. *)

  (** Run [f] inside a BEGIN / COMMIT block.
      Optional [setup] steps run after [BEGIN] (e.g. SET TRANSACTION
      ISOLATION LEVEL).  Optional [cleanup] steps run before [COMMIT]. *)
  val transaction
    :  ?setup:(Caqti_lwt.connection -> (unit, Caqti_error.t) Lwt_result.t) list
    -> ?cleanup:(Caqti_lwt.connection -> (unit, Caqti_error.t) Lwt_result.t) list
    -> Entity.Label.t
    -> (Caqti_lwt.connection -> ('a, Caqti_error.t) Lwt_result.t)
    -> 'a Lwt.t

  (** Run a list of [queries] inside a single transaction. *)
  val transaction_iter
    :  Entity.Label.t
    -> (Caqti_lwt.connection -> (unit, Caqti_error.t) Lwt_result.t) list
    -> unit Lwt.t

end

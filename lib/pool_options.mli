(** Tuning of the connection pools, for {!Pools.Make_with_options}.

    Build one from {!default}:
    {[
    let options = Veins.Pool_options.{ default with statement_timeout = Some 30. }
    ]}

    @canonical Veins.Pool_options *)

type t =
  { max_use_count : int option
    (** Close a connection after this many uses. [None] (default) keeps it;
        Caqti's own default of 100 reconnects every 100 statements of a label
        context. *)
  ; max_idle_size : int option
    (** Connections kept open while idle. [None] (default): the pool size. *)
  ; max_idle_age : float option
    (** Seconds after which an idle connection is closed, so pools of
        databases that are rarely used don't hold connections. Default 300;
        [None] keeps them forever. *)
  ; statement_timeout : float option
    (** Seconds after which the database aborts a statement (MariaDB
        [max_statement_time], PostgreSQL [statement_timeout]), set on every
        new connection. [None] (default): no limit. Migrations run without
        it. *)
  ; acquire_timeout : float option
    (** Seconds a statement waits for a free connection of an exhausted pool
        (connecting included) before it fails with
        [Error.Exn (Connection_failed _)]. [None] (default) waits
        indefinitely. *)
  ; reconnect_backoff : float * float
    (** [(initial, max)] seconds a pool waits, once a reconnect failed,
        before it lets a single statement try again; the wait doubles with
        every failed attempt. Statements in between fail right away with the
        last connection error. The reconnect after the first connection error
        is not delayed. Default [(0.5, 30.)]; [(0., 0.)] retries on every
        statement. *)
  }

val default : t

(** Raises [Invalid_argument] for values that make no sense (negative
    times, a [max_use_count] below 1, …). Called by
    {!Pools.Make_with_options}. *)
val validate : t -> t

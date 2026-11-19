(** Tuning of the connection pools, for {!Pools.Make_with_options}.

    Build one from {!default}:
    {[
    let options = Veins.Pool_options.{ default with statement_timeout = Some 30. }
    ]}

    @canonical Veins.Pool_options *)

(** A statement that failed, for {!t.on_failure}. *)
type failure =
  { label : Entity.Label.t (** The database the statement ran on. *)
  ; role : string option (** The context's role. *)
  ; request : string option
    (** The request as [Caqti.Template.Request.pp] prints it, for [exec],
        [collect], [find] and [find_opt]; [None] for statements run by a
        function ([query], [transaction], [populate], …) and for a request
        that raises when printed (logged). *)
  ; params : string option
    (** The request's parameters, as [Caqti.Template.Row.pp] prints them,
        when there is a [request]: fields of a type marked secret with
        [Row_type.redacted] show as [#redacted#], e.g. a password declared
        [T.(redacted string)] in the request's type. Mark every secret so:
        the rest is printed as it is. [None] when there is no [request] or
        printing raised (logged; a custom type's encoder runs). *)
  ; exn : exn
    (** What the statement raises right after: {!Error.Failed} or
        {!Error.Exn}. *)
  ; connection_error : bool
    (** The database is unreachable: [Pools_sig.Sig.is_connection_error exn],
        for an application that only logs during an outage instead of
        reporting every statement. *)
  }

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
  ; on_failure : (failure -> unit Lwt.t) option
    (** Called with every error a statement raises ({!Error.Failed},
        {!Error.Exn}), e.g. to report it to an error tracker, before it is
        raised: the statement waits for it, so keep it short or let it run
        in the background. Each error is reported once, where veins raises
        it: a statement failing inside [connection_ctx] or
        [transaction_ctx] isn't reported again when it leaves them, nor are
        exceptions of the application's own code. [Pool.ping] and the other
        [Pool] functions don't report. An exception of [on_failure] is
        logged and dropped. Default [None]. *)
  }

val default : t

(** Raises [Invalid_argument] for values that make no sense (negative
    times, a [max_use_count] below 1, …). Called by
    {!Pools.Make_with_options}. *)
val validate : t -> t

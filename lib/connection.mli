(** Caqti connections with the driver bugs veins knows of worked around.

    Every connection veins hands out ([query], [transaction], their
    [setup] / [cleanup], and the ones held by contexts) went through
    {!fixed}, so its whole [Caqti_lwt.CONNECTION] interface is safe to use.
    Only connections taken from a Caqti pool directly ([Pool.fetch]) are
    the driver's own.

    @canonical Veins.Connection *)

(** [fixed connection] is [connection] with, on MariaDB
    (caqti-driver-mariadb 3.1):

    - [rollback] restoring [autocommit]: the driver turns it off to start a
      transaction and back on when committing, but not when rolling back, so
      later statements ran in a transaction that was never committed;
    - [commit] in one round trip, by turning [autocommit] back on (which
      commits), and rolling back when that fails;
    - [with_transaction] rolling back through that [rollback];
    - [populate] inserting all rows or none, 100 per statement, and joining
      the transaction it is called in: the driver's returns after a failing
      row without rolling back, and commits the transaction it is called in.

    PostgreSQL connections are returned as they are.

    Whether a transaction is open is tracked from the [start], [commit] and
    [rollback] calls on the result: fix a connection before starting a
    transaction on it, and use the fixed one from then on. *)
val fixed : Caqti_lwt.connection -> Caqti_lwt.connection

(** [without_fk_checks connection f] runs [f] with the foreign key checks of
    [connection]'s session turned off ({!Dialect.set_fk_checks}), and turns
    them back on when [f] returned [Ok], [Error] or raised. Where the dialect
    has no such switch (PostgreSQL) it just runs [f].

    The switch is session state: run [f]'s statements on [connection] (e.g.
    inside [query]), not on a context that takes another connection.

    If turning the checks off fails, [f] is not run and that error is
    returned. If [f] succeeded but turning them back on fails, that error is
    returned; if [f] failed, its error (or exception) is kept and the
    failure to turn them back on is logged. *)
val without_fk_checks
  :  Caqti_lwt.connection
  -> (unit -> ('a, Caqti.Error.t) Lwt_result.t)
  -> ('a, Caqti.Error.t) Lwt_result.t

(** [test url] connects once to [url] and closes the connection: [Ok ()] if
    the database answered. It needs no pool and touches none, so it serves to
    check a URL before registering its database. PostgreSQL URLs get the
    [connect_timeout] the pools connect with.

    [post_connect] runs on the connection (a {!fixed} one) before it is
    closed, e.g. for session settings that must work, or a statement the
    login must be allowed to run; its error fails the test.

    A failure is [Error.Connection_failed] with a message that shows the URL
    like [Veins.Url.pp], i.e. without its password. To test a database with
    all its logins, see [Pool.test] of {!Pools_sig.Sig}. *)
val test
  :  ?post_connect:(Caqti_lwt.connection -> (unit, Caqti.Error.t) Lwt_result.t)
  -> Entity.Url.t
  -> (unit, Error.t) Lwt_result.t

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
    - [with_transaction] rolling back through that [rollback];
    - [populate] inserting all rows or none, and joining the transaction it
      is called in: the driver's returns after a failing row without rolling
      back, and commits the transaction it is called in.

    PostgreSQL connections are returned as they are.

    Whether a transaction is open is tracked from the [start], [commit] and
    [rollback] calls on the result: fix a connection before starting a
    transaction on it, and use the fixed one from then on. *)
val fixed : Caqti_lwt.connection -> Caqti_lwt.connection

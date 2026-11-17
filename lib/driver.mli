(** What veins needs to know from the database driver: how to read its
    errors.

    Caqti classifies constraint violations ([Caqti.Error.cause]), but not a
    lost connection or a missing privilege; those only show in the driver's
    own error messages (MariaDB errnos, PostgreSQL SQLSTATEs). The driver
    packages implement this signature: [Veins_mariadb.Driver] and
    [Veins_postgresql.Driver]. The SQL itself doesn't depend on the driver,
    see {!Dialect}.

    @canonical Veins.Driver *)

module type Sig = sig
  (** [true] when the error means the connection is gone, so the pool must be
      dropped and reconnected. Any other error (a constraint violation, a
      syntax error, …) leaves the pool alone. *)
  val is_connection_error : Caqti.Error.t -> bool

  (** [true] when the database refused a statement for lack of privileges;
      veins then raises [Error.Permission_denied]. *)
  val is_permission_error : Caqti.Error.t -> bool
end

(** Recognises only connect and load errors, and no permission errors: what
    can be told without knowing the driver. *)
module Generic : Sig

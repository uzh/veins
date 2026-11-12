(** Where statements run: a database context.

    - [Label]: every statement takes a fresh connection from the pool.
    - [Connection]: every statement runs on the same, held connection.
    - [Transaction]: every statement runs on the same connection, inside an
      open transaction.

    The type parameter tells the two apart at compile time
    ({!no_transaction} / {!transaction}), {!val-txn} at runtime. Build contexts
    with [label_ctx], [connection_ctx] and [transaction_ctx] of a pool (see
    {!Pools_sig.Sig}).

    A context names the role it runs as; a held connection keeps that role
    for its whole lifetime, so statements needing more rights fail before
    they are sent instead of switching to another role.

    This design (context type, phantom transaction marker, after-commit
    hooks) was introduced by Reynir Björnsson in the database refactoring of
    the pool tool (uzh/z-pool-tool#647) and moved here from there.

    @canonical Veins.Ctx *)

(** Functions registered with {!after_commit} for one transaction. *)
module After_commit : sig
  type t

  (**/**)

  val create : unit -> t
  val run : on_error:(exn -> unit) -> t -> unit
end

(** Phantom type: the context is not in a transaction. *)
type no_transaction = private [ `no_transaction ]

(** Phantom type: the context is in a transaction. *)
type transaction = private [ `transaction ]

type !_ t = private
  | Label :
      { label : Entity.Label.t
      ; role : Entity.Role.t option
      ; tags : Logs.Tag.set
      }
      -> no_transaction t
  [@ocaml.alert
    abstract
      "This type is meant to be abstract, but is not in order to allow unboxing in a \
       different type."]
  | Connection :
      { connection : Caqti_lwt.connection
      ; label : Entity.Label.t
      ; role : Entity.Role.t option
      ; tags : Logs.Tag.set
      ; mutex : Lwt_mutex.t
      ; capabilities : Entity.Capability.Set.t option
      }
      -> no_transaction t
  [@ocaml.alert
    abstract
      "This type is meant to be abstract, but is not in order to allow unboxing in a \
       different type."]
  | Transaction :
      { connection : Caqti_lwt.connection
      ; label : Entity.Label.t
      ; role : Entity.Role.t option
      ; tags : Logs.Tag.set
      ; mutex : Lwt_mutex.t
      ; capabilities : Entity.Capability.Set.t option
      ; on_commit : After_commit.t
      }
      -> transaction t
  [@ocaml.alert
    abstract
      "This type is meant to be abstract, but is not in order to allow unboxing in a \
       different type."]
(* NOTE(reynir): the type is exposed as private so that we can add
   [[@@ocaml.unboxed]] annotation below in [type any]. If the type is
   abstract the compiler cannot know that [type _ t] does not contain floats
   (which would prevent unboxing due to flat float array hack). *)

(** Runtime witness of the transaction marker, see {!val-txn}. *)
type _ txn = private
  | Yes : transaction txn
  | No : no_transaction txn

(** A context of either kind. *)
type any = Any : 'maybe_txn t -> any [@@ocaml.unboxed]

val txn : 'maybe_txn t -> 'maybe_txn txn
val is_transaction : _ t -> bool
val label : _ t -> Entity.Label.t
val role : _ t -> Entity.Role.t option
val tags : _ t -> Logs.Tag.set

(** [after_commit ctx f] runs [f] right away unless [ctx] is a transaction;
    then [f] runs once it has committed, and is dropped on rollback. Hooks run
    in registration order; one that raises is logged and doesn't stop the
    others (the transaction has committed already). *)
val after_commit : _ t -> (unit -> unit) -> unit

(** Log tag carrying the label of the context. *)
val label_tag : Entity.Label.t Logs.Tag.def

(**/**)

val label_ctx
  :  ?tags:Logs.Tag.set
  -> ?role:Entity.Role.t
  -> Entity.Label.t
  -> no_transaction t

val connection_ctx
  :  ?tags:Logs.Tag.set
  -> ?role:Entity.Role.t
  -> capabilities:Entity.Capability.Set.t option
  -> Entity.Label.t
  -> Caqti_lwt.connection
  -> no_transaction t

val transaction_ctx
  :  ?tags:Logs.Tag.set
  -> ?role:Entity.Role.t
  -> ?mutex:Lwt_mutex.t
  -> capabilities:Entity.Capability.Set.t option
  -> Entity.Label.t
  -> Caqti_lwt.connection
  -> transaction t

(** [on_commit ctx] are the hooks of transaction [ctx]. *)
val on_commit : transaction t -> After_commit.t

val mutex : _ t -> Lwt_mutex.t option
val connection : _ t -> Caqti_lwt.connection option

(** The capabilities of a held connection's role, resolved when it was
    opened ([Some None]: every capability); [None] for a label context, which
    resolves them per statement. *)
val held_capabilities : _ t -> Entity.Capability.Set.t option option

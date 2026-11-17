(** PostgreSQL driver library of Veins: [veins.postgresql] in dune.

    Part of the opam package [veins], installed when [caqti-driver-postgresql]
    is: depend on both in your opam file.

    {[
    module Db = Veins_postgresql.Pools.Make (struct
        let database = Veins.Database.create (Veins.Label.create "root") url
      end)
    ]}

    With one database user for everything, {!Plain} gives the same pools
    without roles and needs. *)

(** How veins reads the PostgreSQL driver's errors: lost connections and
    missing privileges. The SQL veins sends follows the connection's dialect,
    see {!Veins.Dialect}. *)
module Driver : Veins.Driver.Sig

(** The configuration of the [Make_with_options] functors: the primary
    database and the most connections each of its pools keeps open
    ([Veins.Pools_sig.ConfigSig.database_pool_size]). *)
module type CONFIG = sig
  val database : Veins.Database.t
  val database_pool_size : int
end

(** Connection pools with {!Driver} pre-configured. *)
module Pools : sig
  (** {!Veins.Pools.Make} with only [database] to give: [database_pool_size]
      is [10], [expected_databases] is [5] and the options are
      {!Veins.Pool_options.default}. *)
  module Make : functor
      (_ : sig
         val database : Veins.Database.t
       end)
      -> Veins.Pools_sig.Sig

  (** {!Veins.Pools.Make_with_options} with the pool size and the
      {!Veins.Pool_options} chosen:

      {[
      module Db =
        Veins_postgresql.Pools.Make_with_options
          (struct
            let database = Veins.Database.create (Veins.Label.create "root") url
            let database_pool_size = 20
          end)
          (struct
            let options = Veins.Pool_options.{ default with statement_timeout = Some 30. }
          end)
      ]} *)
  module Make_with_options : functor (_ : CONFIG) (_ : Veins.Pools_sig.OptionsSig) ->
    Veins.Pools_sig.Sig
end

(** Pools for one database user, with {!Driver} pre-configured: no roles,
    logins or needs, see {!Veins.Plain}. *)
module Plain : sig
  (** {!Veins.Plain.Make} of {!Pools.Make}.

      {[
      module Db = Veins_postgresql.Plain.Make (struct
          let database = Veins.Database.create (Veins.Label.create "root") url
        end)

      let name = Db.find_opt (Db.label_ctx root) find_name 1
      ]} *)
  module Make : functor
      (_ : sig
         val database : Veins.Database.t
       end)
      -> Veins.Plain.Sig

  (** {!Veins.Plain.Make} of {!Pools.Make_with_options}: the pool size and
      the {!Veins.Pool_options} chosen. *)
  module Make_with_options : functor (_ : CONFIG) (_ : Veins.Pools_sig.OptionsSig) ->
    Veins.Plain.Sig
end

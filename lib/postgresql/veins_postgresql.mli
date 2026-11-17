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

(** Connection pools with {!Driver} pre-configured. *)
module Pools : sig
  (** {!Veins.Pools.Make} with only [database] to give: [database_pool_size]
      is [10] and [expected_databases] is [5].

      For other sizes or for {!Veins.Pool_options}, apply {!Veins.Pools.Make}
      or {!Veins.Pools.Make_with_options} with
      [module Driver = Veins_postgresql.Driver] in the configuration. *)
  module Make : functor
      (_ : sig
         val database : Veins.Database.t
       end)
      -> Veins.Pools_sig.Sig
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
end

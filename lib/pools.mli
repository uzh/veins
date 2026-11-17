(** Makes pools. The configuration ({!Pools_sig.ConfigSig}) and what an
    application gets ({!Pools_sig.Sig}) are in {!Pools_sig}.

    @canonical Veins.Pools *)

(** Pools with {!Pool_options.default}. *)
module Make : functor (Config : Pools_sig.ConfigSig) ->
  Pools_sig.Sig with module Config = Config

(** Pools with their tuning chosen: recycling of connections, timeouts,
    reconnect backoff ({!Pool_options}).

    Raises [Invalid_argument] for options {!Pool_options.validate} refuses. *)
module Make_with_options : functor
    (Config : Pools_sig.ConfigSig)
    (_ : Pools_sig.OptionsSig)
    -> Pools_sig.Sig with module Config = Config

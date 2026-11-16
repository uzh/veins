(** Makes pools. The configuration ({!Pools_sig.ConfigSig}) and what an
    application gets ({!Pools_sig.Sig}) are in {!Pools_sig}.

    @canonical Veins.Pools *)

module Make : functor (Config : Pools_sig.ConfigSig) ->
  Pools_sig.Sig with module Config = Config

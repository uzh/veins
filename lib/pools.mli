(** Public interface for {!Pools}.Make.

    Re-exposes {!Pools_sig.Sig} so callers only need to open {!Veins} and use
    [Veins.Pools.Make] to instantiate a pool. *)

module Make : functor (Config : Pools_sig.ConfigSig) ->
  Pools_sig.Sig with module Config = Config

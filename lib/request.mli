(** A Caqti request plus the capabilities it needs.

    Every statement veins sends is a [Request.t], so the rights it needs are
    declared next to its SQL:

    {[
    let read = Veins.Capability.create "read"

    let find_user =
      {sql| SELECT name FROM users WHERE id = ? |sql}
      |> Caqti_type.(int ->? string)
      |> Veins.Request.create ~needs:[ read ]
    ;;
    ]}

    Before sending it, veins checks that the context's role has every
    capability in [needs]; see {!Error.Insufficient_capabilities}.

    @canonical Veins.Request *)

type ('a, 'b, +'m) t constraint 'm = [< `Zero | `One | `Many ]

val create
  :  needs:Entity.Capability.t list
  -> ('a, 'b, 'm) Caqti_request.t
  -> ('a, 'b, 'm) t

val needs : (_, _, _) t -> Entity.Capability.Set.t
val caqti : ('a, 'b, 'm) t -> ('a, 'b, 'm) Caqti_request.t

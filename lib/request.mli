(** A Caqti request plus the rights it needs.

    Every statement veins sends is a [Request.t], so the rights it needs are
    declared next to its SQL, and are part of its type:

    {[
    let read : [> `Read ] Veins.Need.t = Veins.Need.v "read"

    let find_user =
      {sql| SELECT name FROM users WHERE id = ? |sql}
      |> Caqti_type.(int ->? string)
      |> Veins.Request.create ~needs:read
    ;;
    (* find_user : (int, string, [ `One | `Zero ], [> `Read ]) Veins.Request.t *)
    ]}

    The last type parameter is covariant, so a request defined at the top
    level stays usable on contexts of every role that grants [`Read].
    Running it on a context whose role doesn't is a compile error, see
    {!Ctx.t}.

    @canonical Veins.Request *)

type ('a, 'b, +'m, +'g) t constraint 'm = [< `Zero | `One | `Many ]

val create : needs:'g Entity.Need.t -> ('a, 'b, 'm) Caqti_request.t -> ('a, 'b, 'm, 'g) t
val needs : (_, _, _, 'g) t -> 'g Entity.Need.t
val caqti : ('a, 'b, 'm, _) t -> ('a, 'b, 'm) Caqti_request.t

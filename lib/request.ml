type ('a, 'b, +'m, +'g) t =
  { needs : 'g Entity.Need.t
  ; request : ('a, 'b, 'm) Caqti_request.t
  }
  constraint 'm = [< `Zero | `One | `Many ]

let create ~needs request = { needs; request }
let needs { needs; _ } = needs
let caqti { request; _ } = request

type ('a, 'b, +'m) t =
  { needs : Entity.Capability.Set.t
  ; request : ('a, 'b, 'm) Caqti_request.t
  }
  constraint 'm = [< `Zero | `One | `Many ]

let create ~needs request = { needs = Entity.Capability.Set.of_list needs; request }
let needs { needs; _ } = needs
let caqti { request; _ } = request

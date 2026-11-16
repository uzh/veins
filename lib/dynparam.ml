type t = Pack : 'a Caqti.Template.Row_type.t * 'a -> t

let empty = Pack (Caqti.Template.Row_type.unit, ())
let add t x (Pack (t', x')) = Pack (Caqti.Template.Row_type.t2 t' t, (x', x))
let prefix t x (Pack (t', x')) = Pack (Caqti.Template.Row_type.t2 t t', (x, x'))

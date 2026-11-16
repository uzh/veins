(** Parameters of a statement whose number is only known at runtime, e.g. a
    filter built from a form: collect each value with its row type, then
    unpack both for the request.

    {[
    let (Pack (row_type, values)) =
      Veins.Dynparam.(empty |> add T.string name |> add T.int age)
    in
    (* row_type : ((unit * string) * int) Caqti.Template.Row_type.t *)
    ]}

    @canonical Veins.Dynparam *)

type t = Pack : 'a Caqti.Template.Row_type.t * 'a -> t

(** No parameters. *)
val empty : t

(** [add row_type value params] is [params] followed by [value]. *)
val add : 'a Caqti.Template.Row_type.t -> 'a -> t -> t

(** [prefix row_type value params] is [value] followed by [params]. *)
val prefix : 'a Caqti.Template.Row_type.t -> 'a -> t -> t

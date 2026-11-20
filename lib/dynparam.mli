(** Parameters of a statement whose number is only known at runtime, e.g. a
    filter built from a form: collect each value with its row type, then
    unpack both for the request.

    {[
    let (Pack (row_type, values)) =
      Veins.Dynparam.(empty |> add T.string name |> add T.int age)
    in
    (* row_type : ((unit * string) * int) Caqti.Template.Row_type.t *)
    ]}

    Build a request whose SQL changes with the parameters (a filter, an
    [IN (?, ?, …)] of varying length) as [dynamic] or [direct], never
    [static]: Caqti keeps a static request's prepared statement on the
    connection as long as it lives, one per distinct SQL text, and MariaDB
    refuses to prepare any statement once the server holds
    [max_prepared_stmt_count] (16382 by default). Caqti releases dynamic
    ones, least recently used first.

    @canonical Veins.Dynparam *)

type t = Pack : 'a Caqti.Template.Row_type.t * 'a -> t

(** No parameters. *)
val empty : t

(** [add row_type value params] is [params] followed by [value]. *)
val add : 'a Caqti.Template.Row_type.t -> 'a -> t -> t

(** [prefix row_type value params] is [value] followed by [params]. *)
val prefix : 'a Caqti.Template.Row_type.t -> 'a -> t -> t

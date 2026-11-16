(** Caqti row types for values with custom encoders and decoders, written as
    lists instead of nested tuples.

    {[
    type user =
      { id : Id.t
      ; name : string
      ; age : int option
      }

    let user =
      let open Veins.Caqti_encoders in
      let module T = Caqti.Template.Row_type in
      let encode u : (_ Data.t, _) result = Ok Data.[ u.id; u.name; u.age ] in
      let decode (id, (name, (age, ()))) = Ok { id; name; age } in
      custom ~encode ~decode Schema.[ Id.t; T.string; T.option T.int ]
    ;;
    ]}

    A schema of [n] columns is the row type
    [t2 c1 (t2 c2 (... (t2 cn unit)))], so the decoder receives nested pairs
    ending in [()]. *)

(** The values of one row, in schema order. *)
module Data : sig
  type _ t =
    | [] : unit t
    | ( :: ) : ('a * 'b t) -> ('a * 'b) t

  (** The nested pairs the list stands for. *)
  val make_value : 'a t -> 'a
end

(** The column types of one row. *)
module Schema : sig
  type _ t =
    | [] : unit t
    | ( :: ) : ('a Caqti.Template.Row_type.t * 'b t) -> ('a * 'b) t

  (** The row type the schema stands for.

      @raise Invalid_argument if the schema is empty. *)
  val make_type : 'a t -> 'a Caqti.Template.Row_type.t
end

(** [custom ~encode ~decode schema] is a row type for ['b] represented by
    [schema]. An [Error] from [encode] or [decode] fails the statement with
    Caqti's encode / decode error.

    @raise Invalid_argument if the schema is empty. *)
val custom
  :  encode:('b -> ('a Data.t, string) result)
  -> decode:('a -> ('b, string) result)
  -> 'a Schema.t
  -> 'b Caqti.Template.Row_type.t

(** {!custom} for an [encode] and a [decode] that cannot fail. *)
val custom_ok
  :  encode:('b -> 'a Data.t)
  -> decode:('a -> 'b)
  -> 'a Schema.t
  -> 'b Caqti.Template.Row_type.t

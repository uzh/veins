module Data = struct
  type _ t =
    | [] : unit t
    | ( :: ) : ('a * 'b t) -> ('a * 'b) t

  let rec make_value : type a. a t -> a =
    fun xs ->
    match xs with
    | [] -> ()
    | x :: xs -> x, make_value xs
  ;;
end

module Schema = struct
  type _ t =
    | [] : unit t
    | ( :: ) : ('a Caqti.Template.Row_type.t * 'b t) -> ('a * 'b) t

  let rec make_type : type a. a t -> a Caqti.Template.Row_type.t =
    fun xs ->
    match xs with
    | [] -> invalid_arg "Veins.Caqti_encoders.Schema.make_type: empty schema"
    | x :: [] -> Caqti.Template.Row_type.(t2 x unit)
    | x :: xs -> Caqti.Template.Row_type.(t2 x (make_type xs))
  ;;
end

let custom ~encode ~decode schema =
  let encode data = encode data |> Result.map Data.make_value in
  Caqti.Template.Row_type.custom ~encode ~decode (Schema.make_type schema)
;;

let custom_ok ~encode ~decode schema =
  custom
    ~encode:(fun data -> Ok (encode data))
    ~decode:(fun row -> Ok (decode row))
    schema
;;

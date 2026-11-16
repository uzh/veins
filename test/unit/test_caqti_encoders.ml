(** Unit tests for {!Veins.Caqti_encoders} that require no database. *)

open Veins
module T = Caqti.Template.Row_type

let test_data () =
  let open Caqti_encoders in
  Alcotest.(check (pair int (pair string unit)))
    "nested pairs"
    (1, ("one", ()))
    (Data.make_value Data.[ 1; "one" ])
;;

let test_schema () =
  let open Caqti_encoders in
  let typ = Schema.make_type Schema.[ T.int; T.string; T.option T.bool ] in
  Alcotest.(check int) "columns" 3 (T.length typ);
  Alcotest.(check string)
    "shape"
    (T.show T.(t2 int (t2 string (t2 (option bool) unit))))
    (T.show typ);
  Alcotest.check_raises
    "empty schema"
    (Invalid_argument "Veins.Caqti_encoders.Schema.make_type: empty schema")
    (fun () -> ignore (Schema.make_type Schema.[]))
;;

let test_custom () =
  let open Caqti_encoders in
  let encode (id, name) : _ Data.t = Data.[ id; name ] in
  let decode (id, (name, ())) = id, name in
  let checked =
    custom
      ~encode:(fun x -> Ok (encode x))
      ~decode:(fun x -> Ok (decode x))
      Schema.[ T.int; T.string ]
  in
  let unchecked = custom_ok ~encode ~decode Schema.[ T.int; T.string ] in
  Alcotest.(check int) "custom columns" 2 (T.length checked);
  Alcotest.(check int) "custom_ok columns" 2 (T.length unchecked)
;;

let () =
  Alcotest.run
    "Veins Caqti_encoders"
    [ "data", [ Alcotest.test_case "make_value" `Quick test_data ]
    ; "schema", [ Alcotest.test_case "make_type" `Quick test_schema ]
    ; "custom", [ Alcotest.test_case "custom / custom_ok" `Quick test_custom ]
    ]
;;

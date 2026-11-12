(** Unit tests for {!Veins.Entity} that require no database. *)

open Veins

let test_label_roundtrip () =
  let s = "my_tenant" in
  let l = Label.create s in
  assert (Label.value l = s);
  assert (Label.equal l (Label.create s));
  assert (Label.show l = s)
;;

let test_url_roundtrip () =
  let raw = "mariadb://user:pass@host/db" in
  let u = Url.create raw in
  assert (Url.equal u (Url.create raw))
;;

let test_url_redacts_password () =
  let u = Url.create "postgresql://admin:s3cr3t@host:5432/mydb" in
  let shown = Url.show u in
  assert (not (CCString.mem ~sub:"s3cr3t" shown));
  assert (CCString.mem ~sub:"admin" shown);
  assert (CCString.mem ~sub:"host" shown);
  let u_no_pass = Url.create "postgresql://admin@host/mydb" in
  assert (Url.show u_no_pass = "postgresql://admin@host/mydb")
;;

let test_status_roundtrip () =
  let open Status in
  CCList.iter
    (fun st ->
       match of_string (show st) with
       | Ok s -> assert (equal s st)
       | Error e -> invalid_arg e)
    all
;;

let test_dynparam () =
  let open Dynparam in
  let (Pack (t, v)) = empty |> add Caqti_type.int 42 |> add Caqti_type.string "hello" in
  ignore (t, v)
;;

let () =
  Alcotest.run
    "Veins Entity"
    [ "label", [ Alcotest.test_case "roundtrip" `Quick test_label_roundtrip ]
    ; ( "url"
      , [ Alcotest.test_case "roundtrip" `Quick test_url_roundtrip
        ; Alcotest.test_case "redacts_password" `Quick test_url_redacts_password
        ] )
    ; "status", [ Alcotest.test_case "roundtrip" `Quick test_status_roundtrip ]
    ; "dynparam", [ Alcotest.test_case "create" `Quick test_dynparam ]
    ]
;;

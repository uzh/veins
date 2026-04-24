(** Unit tests for {!Vena.Entity} that require no database. *)

open Vena

let test_label_roundtrip () =
  let s = "my_tenant" in
  let l = Entity.Label.create s in
  assert (Entity.Label.value l = s);
  assert (Entity.Label.equal l (Entity.Label.create s));
  assert (Entity.Label.show l = s)
;;

let test_url_uri () =
  let raw = "mariadb://user:pass@host/db" in
  let u = Entity.Url.create raw in
  assert (Entity.Url.value u = raw);
  let uri = Entity.Url.to_uri u in
  assert (Uri.scheme uri = Some "mariadb")
;;

let test_status_roundtrip () =
  let open Entity.Status in
  CCList.iter
    (fun st ->
      match of_string (show st) with
      | Ok s -> assert (equal s st)
      | Error e -> failwith e)
    all
;;

let test_dynparam () =
  let open Entity.Dynparam in
  let (Pack (t, v)) =
    empty
    |> add Caqti_type.int 42
    |> add Caqti_type.string "hello"
  in
  ignore (t, v)
;;

let () =
  test_label_roundtrip ();
  test_url_uri ();
  test_status_roundtrip ();
  test_dynparam ();
  print_endline "All entity unit tests passed."
;;

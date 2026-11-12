(** Unit tests for {!Veins.Entity} that require no database. *)

open Veins
open Caqti_request.Infix

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

let read = Capability.create "read"
let write = Capability.create "write"
let url = Url.create "mariadb://user@host/db"
let reader = Role.create "reader" ~capabilities:[ read ]
let writer = Role.create "writer" ~capabilities:[ read; write ]

let raises_invalid_argument f =
  match f () with
  | (_ : _) -> Alcotest.fail "expected Invalid_argument"
  | exception Invalid_argument _ -> ()
;;

let test_capability_names_are_unique () =
  Alcotest.(check string) "name" "read" (Capability.name read);
  raises_invalid_argument (fun () -> Capability.create "read")
;;

let test_capability_sets () =
  let open Capability.Set in
  Alcotest.(check bool)
    "subset"
    true
    (subset (of_list [ read ]) (Role.capabilities writer));
  Alcotest.(check bool)
    "not subset"
    false
    (subset (of_list [ write ]) (Role.capabilities reader));
  Alcotest.(check (list string))
    "missing"
    [ "write" ]
    (diff (of_list [ read; write ]) (Role.capabilities reader)
     |> elements
     |> CCList.map Capability.name)
;;

let test_role_equality_by_name () =
  Alcotest.(check bool)
    "same name"
    true
    (Role.equal reader (Role.create "reader" ~capabilities:[ read; write ]))
;;

let test_database_roles () =
  let db =
    Database.create (Label.create "db") (Database.Multiple [ reader, url; writer, url ])
  in
  Alcotest.(check (list string))
    "roles"
    [ "reader"; "writer" ]
    (Database.roles db |> CCList.map Role.value);
  (* the database's role wins: a role named like it, with other capabilities *)
  let configured = Database.find_role db (Role.create "reader") |> Option.get in
  Alcotest.(check bool)
    "configured capabilities"
    true
    (Capability.Set.mem read (Role.capabilities configured));
  Alcotest.(check bool)
    "unknown role"
    true
    (Option.is_none (Database.find_role db (Role.create "admin")));
  raises_invalid_argument (fun () -> Database.url db);
  raises_invalid_argument (fun () -> Database.url ~role:(Role.create "admin") db);
  Alcotest.(check bool) "role url" true (Url.equal url (Database.url ~role:writer db))
;;

let test_database_create_validates () =
  raises_invalid_argument (fun () ->
    Database.create (Label.create "db") (Database.Multiple [ reader, url; reader, url ]));
  raises_invalid_argument (fun () ->
    Database.create (Label.create "db") (Database.Multiple []))
;;

let test_main_role_policy () =
  let fallback = Database.create (Label.create "db") (Database.Main url) in
  let strict =
    Database.create ~role_policy:Database.Strict (Label.create "db") (Database.Main url)
  in
  Alcotest.(check bool)
    "fallback"
    true
    (Url.equal url (Database.url ~role:reader fallback));
  Alcotest.(check bool) "no role" true (Url.equal url (Database.url strict));
  raises_invalid_argument (fun () -> Database.url ~role:reader strict)
;;

let test_request_needs () =
  let request =
    Caqti_type.(unit ->! int) "SELECT 1" |> Request.create ~needs:[ read; read ]
  in
  Alcotest.(check (list string))
    "needs"
    [ "read" ]
    (Request.needs request |> Capability.Set.elements |> CCList.map Capability.name)
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
    ; ( "capability"
      , [ Alcotest.test_case "names are unique" `Quick test_capability_names_are_unique
        ; Alcotest.test_case "sets" `Quick test_capability_sets
        ] )
    ; "role", [ Alcotest.test_case "equal by name" `Quick test_role_equality_by_name ]
    ; ( "database"
      , [ Alcotest.test_case "roles" `Quick test_database_roles
        ; Alcotest.test_case
            "create validates roles"
            `Quick
            test_database_create_validates
        ; Alcotest.test_case "main role policy" `Quick test_main_role_policy
        ] )
    ; "request", [ Alcotest.test_case "needs" `Quick test_request_needs ]
    ]
;;

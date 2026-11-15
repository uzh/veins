(** Unit tests for {!Veins.Entity} that require no database. *)

open Veins
module T = Caqti.Templater.T

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
  assert (Url.show u_no_pass = "postgresql://admin@host/mydb");
  let in_query =
    Url.show
      (Url.create "postgresql://host/mydb?user=admin&password=s3cr3t&sslpassword=k3y")
  in
  assert (not (CCString.mem ~sub:"s3cr3t" in_query));
  assert (not (CCString.mem ~sub:"k3y" in_query));
  assert (CCString.mem ~sub:"user=admin" in_query)
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
  let (Pack (t, v)) = empty |> add T.int 42 |> add T.string "hello" in
  ignore (t, v)
;;

let read : [> `Read ] Need.t = Need.v "read"
let write : [> `Write ] Need.t = Need.v "write"
let url = Url.create "mariadb://user@host/db"
let query_url = Url.create "mariadb://query@host/db"
let query_login = Login.create "query"

let raises_invalid_argument f =
  match f () with
  | (_ : _) -> Alcotest.fail "expected Invalid_argument"
  | exception Invalid_argument _ -> ()
;;

let test_login () =
  Alcotest.(check string) "name" "query" (Login.name query_login);
  Alcotest.(check bool) "owner" true (Login.is_owner Login.owner);
  Alcotest.(check bool) "not the owner" false (Login.is_owner query_login);
  raises_invalid_argument (fun () -> Login.create "owner")
;;

let test_need_names () =
  Alcotest.(check (list string)) "none" [] (Need.names Need.none);
  Alcotest.(check (list string))
    "combined, sorted, without duplicates"
    [ "read"; "write" ]
    (Need.names Need.(write & read & read))
;;

let test_role () =
  let query : [ `Read ] Role.t = Role.v ~login:query_login "query" in
  let local : [ `Read ] Role.t = Role.v "local" in
  Alcotest.(check string) "name" "query" (Role.name query);
  Alcotest.(check bool) "login" true (Login.equal query_login (Role.login query));
  Alcotest.(check bool) "default login" true (Login.is_owner (Role.login local));
  Alcotest.(check bool) "owner" true (Login.is_owner (Role.login Role.owner))
;;

let test_database_logins () =
  let single = Database.create (Label.create "db") url in
  let separated =
    Database.create ~logins:[ query_login, query_url ] (Label.create "db") url
  in
  Alcotest.(check int) "single: no logins" 0 (CCList.length (Database.logins single));
  Alcotest.(check bool)
    "single: a login connects as the owner"
    true
    (Url.equal url (Database.url single query_login));
  Alcotest.(check bool)
    "separated: has the login"
    true
    (Database.has_login separated query_login);
  Alcotest.(check bool)
    "separated: the login's URL"
    true
    (Url.equal query_url (Database.url separated query_login));
  Alcotest.(check bool)
    "separated: the owner's URL"
    true
    (Url.equal url (Database.url separated Login.owner));
  Alcotest.(check bool)
    "separated: another login connects as the owner"
    true
    (Url.equal url (Database.url separated (Login.create "command")))
;;

let test_database_create_validates () =
  raises_invalid_argument (fun () ->
    Database.create
      ~logins:[ query_login, query_url; query_login, url ]
      (Label.create "db")
      url);
  raises_invalid_argument (fun () ->
    Database.create ~logins:[ Login.owner, query_url ] (Label.create "db") url)
;;

let test_request_needs () =
  let request =
    Caqti.Templater.static T.(unit -->! int) "SELECT 1"
    |> Request.create ~needs:Need.(read & write)
  in
  Alcotest.(check (list string))
    "needs"
    [ "read"; "write" ]
    (Request.needs request |> Need.names)
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
    ; "login", [ Alcotest.test_case "owner is reserved" `Quick test_login ]
    ; "need", [ Alcotest.test_case "names" `Quick test_need_names ]
    ; "role", [ Alcotest.test_case "login" `Quick test_role ]
    ; ( "database"
      , [ Alcotest.test_case "logins" `Quick test_database_logins
        ; Alcotest.test_case
            "create validates logins"
            `Quick
            test_database_create_validates
        ] )
    ; "request", [ Alcotest.test_case "needs" `Quick test_request_needs ]
    ]
;;

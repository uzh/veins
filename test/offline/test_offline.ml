(* Pool behaviour that needs no database: a fake server stands in for one
   that went away, and counts the connections it got. Whether a statement
   fits its role is checked by the compiler, see test/typing. *)

open Veins
module T = Caqti.Templater.T

module Config = struct
  let database () =
    Database.create (Label.create "unused") (Url.create "mariadb://unused/x")
  ;;

  let database_pool_size = 5
  let expected_databases = 4

  module Driver = Veins_mariadb.Driver
end

(* Reconnects on every statement, so the tests can count connections. *)
module Db =
  Pools.Make_with_options
    (Config)
    (struct
      let options = Pool_options.{ default with reconnect_backoff = 0., 0. }
    end)

module Backoff =
  Pools.Make_with_options
    (Config)
    (struct
      let options = Pool_options.{ default with reconnect_backoff = 2., 2. }
    end)

let ping =
  Caqti.Templater.static T.(unit -->! int) "SELECT 1" |> Request.create ~needs:Roles.read
;;

let owner_ctx label = Db.label_ctx ~role:Role.owner label

let with_server f =
  let%lwt server = Net.Unresponsive.start () in
  Lwt.finalize (fun () -> f server) (fun () -> Net.Unresponsive.stop server)
;;

let url server = Url.create (Net.Unresponsive.url server ~scheme:"mariadb")

let expect name f check =
  match%lwt f () with
  | (_ : _) -> Alcotest.failf "%s: expected an exception" name
  | exception exn -> Lwt.return (check exn)
;;

(* Every failing query disconnects its pool, and disconnecting drains it.
   Caqti's [Pool.drain] wakes a single waiter once the pool runs empty, so two
   drains of the same pool left one of them, and the query behind it, pending
   forever (pool tool #637). *)
let test_unreachable_database_settles_every_query () =
  with_server
  @@ fun server ->
  let label = Label.create "veins_unreachable" in
  Db.Pool.add (Database.create label (url server));
  let query () =
    Lwt.catch
      (fun () -> Db.find (owner_ctx label) ping () |> Lwt.map (fun (_ : int) -> ()))
      (fun (_ : exn) -> Lwt.return_unit)
  in
  let queries = CCList.init 5 (fun (_ : int) -> query ()) in
  let%lwt settled =
    Lwt.pick
      [ Lwt.join queries |> Lwt.map (fun () -> true)
      ; Lwt_unix.sleep 30.0 |> Lwt.map (fun () -> false)
      ]
  in
  let pending = CCList.count (fun query -> Lwt.state query = Lwt.Sleep) queries in
  Db.Pool.drop label;
  Alcotest.(check int) "no query is left pending" 0 pending;
  Lwt.return (Alcotest.(check bool) "every failing query settles" true settled)
;;

(* A pool that failed must try again on the next call (pool tool #624). *)
let test_failed_pool_retries () =
  with_server
  @@ fun server ->
  let label = Label.create "veins_retry" in
  Db.Pool.add (Database.create label (url server));
  let attempt () =
    Lwt.catch
      (fun () -> Db.find (owner_ctx label) ping () |> Lwt.map (fun (_ : int) -> ()))
      (fun (_ : exn) -> Lwt.return_unit)
  in
  let%lwt () = attempt () in
  let%lwt () = attempt () in
  let after_two = server.Net.Unresponsive.accepted in
  let%lwt () = attempt () in
  let%lwt () = attempt () in
  Db.Pool.drop label;
  Lwt.return
    (Alcotest.(check bool)
       "later calls still reach the server"
       true
       (server.Net.Unresponsive.accepted > after_two))
;;

(* The first connection error reconnects right away. When that fails too,
   the pool fails without connecting until its backoff is over, then lets one
   statement try again. *)
let test_backoff () =
  with_server
  @@ fun server ->
  let label = Label.create "veins_backoff" in
  Backoff.Pool.add (Database.create label (url server));
  let attempt () =
    let started = Unix.gettimeofday () in
    let%lwt () =
      Lwt.catch
        (fun () ->
           Backoff.find (Backoff.label_ctx ~role:Role.owner label) ping ()
           |> Lwt.map (fun (_ : int) -> ()))
        (function
          | Error.Failed _ -> Lwt.return_unit
          | exn -> Lwt.reraise exn)
    in
    Lwt.return (Unix.gettimeofday () -. started)
  in
  let%lwt (_ : float) = attempt () in
  let%lwt (_ : float) = attempt () in
  let after_first = server.Net.Unresponsive.accepted in
  Alcotest.(check int) "the reconnect is tried right away" 2 after_first;
  let%lwt waited = attempt () in
  let%lwt (_ : float) = attempt () in
  Alcotest.(check int)
    "no connection attempt during the backoff"
    after_first
    server.Net.Unresponsive.accepted;
  Alcotest.(check bool) "failed right away" true (waited < 0.2);
  let%lwt pinged = Backoff.Pool.ping label in
  Alcotest.(check bool) "ping fails during the backoff" true (Result.is_error pinged);
  let%lwt () = Lwt_unix.sleep 2.1 in
  (* one statement tries, the ones arriving meanwhile still fail right away *)
  let trying = attempt () in
  let%lwt waited = attempt () in
  Alcotest.(check bool) "others don't wait for the attempt" true (waited < 0.2);
  let%lwt (_ : float) = trying in
  Backoff.Pool.drop label;
  Lwt.return
    (Alcotest.(check int)
       "one attempt after the backoff"
       (after_first + 1)
       server.Net.Unresponsive.accepted)
;;

(* [Pool.use] returns what goes wrong as Caqti's errors, reconnects and backs
   off like every statement, and raises only for setup errors. *)
let test_use_returns_errors () =
  with_server
  @@ fun server ->
  let label = Label.create "veins_use" in
  Backoff.Pool.add (Database.create label (url server));
  let select (module C : Caqti_lwt.CONNECTION) =
    C.find (Caqti.Templater.static T.(unit -->! int) "SELECT 1") ()
  in
  let use () =
    match%lwt Backoff.Pool.use label select with
    | Ok (_ : int) -> Alcotest.fail "use: expected an error"
    | Error (_ : Caqti.Error.t) -> Lwt.return_unit
  in
  let%lwt () = use () in
  let%lwt () = use () in
  Alcotest.(check int)
    "reconnects after a connection error"
    2
    server.Net.Unresponsive.accepted;
  let started = Unix.gettimeofday () in
  let%lwt () = use () in
  Alcotest.(check bool)
    "fails right away during the backoff"
    true
    (Unix.gettimeofday () -. started < 0.2);
  Alcotest.(check int) "no connection attempt" 2 server.Net.Unresponsive.accepted;
  Backoff.Pool.drop label;
  let%lwt () =
    expect
      "unregistered label"
      (fun () -> Backoff.Pool.use (Label.create "veins_unknown") select)
      (function
        | Error.Exn (Error.Database_not_registered _) -> ()
        | exn ->
          Alcotest.failf
            "expected Database_not_registered, got %s"
            (Printexc.to_string exn))
  in
  Lwt.return_unit
;;

(* An acquire timeout of [Pool.use] is a [`Connect_failed] whose URI shows
   no password, neither the user's nor one in the query. *)
module Timing_out =
  Pools.Make_with_options
    (Config)
    (struct
      let options = Pool_options.{ default with acquire_timeout = Some 0.1 }
    end)

let test_use_timeout_hides_passwords () =
  with_server
  @@ fun server ->
  let label = Label.create "veins_use_timeout" in
  let url =
    Format.asprintf
      "mariadb://root:userpw@127.0.0.1:%d/test?password=querypw&sslpassword=sslpw"
      server.Net.Unresponsive.port
  in
  Timing_out.Pool.add (Database.create label (Url.create url));
  let%lwt result = Timing_out.Pool.use label (fun _ -> Lwt_result.return ()) in
  Timing_out.Pool.drop label;
  match result with
  | Ok () -> Alcotest.fail "expected an acquire timeout"
  | Error (`Connect_failed _ as error) ->
    let shown = Caqti.Error.show error in
    CCList.iter
      (fun secret ->
         Alcotest.(check bool)
           (Format.asprintf "%s hidden in %s" secret shown)
           false
           (CCString.mem ~sub:secret shown))
      [ "userpw"; "querypw"; "sslpw" ];
    Lwt.return_unit
  | Error error ->
    Alcotest.failf "expected Connect_failed, got %s" (Caqti.Error.show error)
;;

(* A database that separates its users refuses a login it has no URL for,
   instead of running its roles as the owner. *)
let test_strict_logins () =
  with_server
  @@ fun server ->
  let label = Label.create "veins_strict" in
  Db.Pool.add
    (Database.create
       ~strict_logins:true
       ~logins:[ Roles.writer_login, url server ]
       label
       (url server));
  let%lwt () =
    expect
      "login without URL"
      (fun () -> Db.find (Db.label_ctx ~role:Roles.reader label) ping ())
      (function
        | Error.Exn (Error.Login_not_configured { login; _ }) ->
          Alcotest.(check string) "login" "reader" login
        | exn ->
          Alcotest.failf "expected Login_not_configured, got %s" (Printexc.to_string exn))
  in
  Alcotest.(check int) "nothing was sent" 0 server.Net.Unresponsive.accepted;
  let%lwt (_ : _ Caqti_lwt_unix.Pool.t) = Db.Pool.fetch label in
  let%lwt (_ : _ Caqti_lwt_unix.Pool.t) = Db.Pool.fetch ~login:Roles.writer_login label in
  Db.Pool.drop label;
  Lwt.return_unit
;;

(* Without a URL of its own, a login connects with the owner's pool: a
   database with a single user needs nothing but its URL. *)
let test_logins_share_the_owner_pool () =
  with_server
  @@ fun server ->
  let label = Label.create "veins_single" in
  Db.Pool.add (Database.create label (url server));
  let%lwt owner_pool = Db.Pool.fetch label in
  let%lwt reader_pool = Db.Pool.fetch ~login:Roles.reader_login label in
  Alcotest.(check bool) "same pool" true (owner_pool == reader_pool);
  let%lwt () =
    expect
      "reader on the owner's URL"
      (fun () -> Db.find (Db.label_ctx ~role:Roles.reader label) ping ())
      (function
        | Error.Failed { Error.login; role; _ } ->
          Alcotest.(check string) "login" "owner" (Login.name login);
          Alcotest.(check (option string)) "role" (Some "reader") role
        | exn -> Alcotest.failf "expected Failed, got %s" (Printexc.to_string exn))
  in
  Db.Pool.drop label;
  Lwt.return
    (Alcotest.(check bool)
       "sent to the owner's URL"
       true
       (server.Net.Unresponsive.accepted > 0))
;;

let test_registry () =
  with_server
  @@ fun server ->
  let label = Label.create "veins_logins" in
  Db.Pool.add
    (Database.create
       ~logins:[ Roles.reader_login, url server; Roles.writer_login, url server ]
       label
       (url server));
  Alcotest.(check bool)
    "database with logins is listed"
    true
    (CCList.exists
       (fun db -> Label.equal (Database.label db) label)
       (Db.Pool.find_all ()));
  let%lwt owner_pool = Db.Pool.fetch label in
  let%lwt reader_pool = Db.Pool.fetch ~login:Roles.reader_login label in
  let%lwt writer_pool = Db.Pool.fetch ~login:Roles.writer_login label in
  let%lwt migrator_pool = Db.Pool.fetch ~login:Roles.migrator_login label in
  Alcotest.(check bool) "one pool per login" true (reader_pool != writer_pool);
  Alcotest.(check bool) "apart from the owner's" true (reader_pool != owner_pool);
  Alcotest.(check bool)
    "a login without URL: the owner's"
    true
    (migrator_pool == owner_pool);
  (* adding the label again is skipped, the pools stay *)
  Db.Pool.add (Database.create label (Url.create "mariadb://other/x"));
  Alcotest.(check int)
    "kept the first registration"
    2
    (Db.Pool.find label |> Option.get |> Database.logins |> CCList.length);
  let%lwt reader_pool' = Db.Pool.fetch ~login:Roles.reader_login label in
  Alcotest.(check bool) "same pool" true (reader_pool == reader_pool');
  Db.Pool.drop label;
  Alcotest.(check bool) "dropped" true (Option.is_none (Db.Pool.find label));
  expect
    "dropped label"
    (fun () -> Db.Pool.fetch ~login:Roles.reader_login label)
    (function
      | Error.Exn (Error.Database_not_registered _) -> ()
      | exn -> Alcotest.failf "dropped label: unexpected %s" (Printexc.to_string exn))
;;

(* Checking a URL before registering it: a failure says why, without the
   password, and registers nothing. *)
let test_connection_test_hides_the_password () =
  let registered () = CCList.length (Db.Pool.find_all ()) in
  let before = registered () in
  let%lwt socket, port = Net.listen () in
  let%lwt () = Net.close_quietly socket in
  let fails name url ~secret =
    match%lwt Connection.test (Url.create url) with
    | Ok () -> Alcotest.failf "%s: expected an error" name
    | Error (Error.Connection_failed message) ->
      Alcotest.(check bool)
        (Format.asprintf "%s: %s without the password" name message)
        false
        (CCString.mem ~sub:secret message);
      Lwt.return message
    | Error error -> Alcotest.failf "%s: unexpected %s" name (Error.show error)
  in
  let%lwt (_ : string) =
    fails
      "userinfo"
      (Format.asprintf "mariadb://user:s3cr3t-pw@127.0.0.1:%d/x" port)
      ~secret:"s3cr3t-pw"
  in
  let%lwt (_ : string) =
    fails
      "query"
      (Format.asprintf "mariadb://user@127.0.0.1:%d/x?password=s3cr3t-q" port)
      ~secret:"s3cr3t-q"
  in
  let%lwt message =
    fails "no driver" "nodriver://user:s3cr3t-nd@x/y" ~secret:"s3cr3t-nd"
  in
  Alcotest.(check bool)
    ("no driver: names the scheme: " ^ message)
    true
    (CCString.mem ~sub:"nodriver" message);
  Lwt.return (Alcotest.(check int) "nothing registered" before (registered ()))
;;

(* A failed test of the registered database is its connection issue; testing
   other URLs for its label, or a database in another status, changes
   nothing. *)
let test_database_test_tracks_connection_issue () =
  let%lwt socket, port = Net.listen () in
  let%lwt () = Net.close_quietly socket in
  let closed name =
    Url.create (Format.asprintf "mariadb://%s:pw@127.0.0.1:%d/x" name port)
  in
  let label = Label.create "veins_tested" in
  let status () = Db.Pool.find label |> Option.get |> Database.status |> Status.show in
  let fails name database =
    match%lwt Db.Pool.test database with
    | Ok () -> Alcotest.failf "%s: expected an error" name
    | Error (Error.Connection_failed message) -> Lwt.return message
    | Error error -> Alcotest.failf "%s: unexpected %s" name (Error.show error)
  in
  let database =
    Database.create ~logins:[ Roles.reader_login, closed "reader" ] label (closed "owner")
  in
  Db.Pool.add database;
  Lwt.finalize
    (fun () ->
       let%lwt (_ : string) =
         fails "other URLs" (Database.create label (closed "other"))
       in
       Alcotest.(check string) "other URLs tell nothing" "active" (status ());
       let%lwt message = fails "registered" database in
       Alcotest.(check bool)
         ("stops at the first failure, the owner's: " ^ message)
         true
         (CCString.mem ~sub:"owner" message && not (CCString.mem ~sub:"reader" message));
       Alcotest.(check string) "connection issue" "connection_issue" (status ());
       let%lwt (_ : string) = fails "again" database in
       Alcotest.(check string) "still a connection issue" "connection_issue" (status ());
       let disabled = Database.with_status Status.Disabled database in
       Db.Pool.reset disabled;
       let%lwt (_ : string) = fails "disabled" disabled in
       Lwt.return (Alcotest.(check string) "other statuses stay" "disabled" (status ())))
    (fun () -> Lwt.return (Db.Pool.drop label))
;;

let test_mariadb_permission_errors () =
  let error errno =
    Caqti.Error.request_failed
      ~uri:(Uri.of_string "mariadb://x/y")
      ~query:"INSERT INTO t VALUES (1)"
      (Caqti_driver_mariadb.Error_msg { errno; error = "denied" })
  in
  let is_permission errno = Veins_mariadb.Driver.is_permission_error (error errno) in
  let is_connection errno = Veins_mariadb.Driver.is_connection_error (error errno) in
  CCList.iter
    (fun errno ->
       Alcotest.(check bool)
         (Format.asprintf "%d is a permission error" errno)
         true
         (is_permission errno);
       Alcotest.(check bool)
         (Format.asprintf "%d keeps the pool" errno)
         false
         (is_connection errno))
    [ 1044; 1142; 1143; 1227; 1370 ];
  CCList.iter
    (fun errno ->
       Alcotest.(check bool)
         (Format.asprintf "%d is not a permission error" errno)
         false
         (is_permission errno))
    [ 1062; 1146; 2013 ];
  CCList.iter
    (fun errno ->
       Alcotest.(check bool)
         (Format.asprintf "%d drops the pool" errno)
         true
         (is_connection errno))
    [ 1053; 1152; 1158; 1161; 1927; 2006; 2013; 4031 ];
  CCList.iter
    (fun errno ->
       Alcotest.(check bool)
         (Format.asprintf "%d keeps the pool" errno)
         false
         (is_connection errno))
    [ 1062; 1146; 1153; 1205 ];
  Lwt.return_unit
;;

(* [Pool.initialize] reads the primary database, making the module doesn't:
   a configuration loaded at startup is seen. *)
let configured_url = ref None

module Deferred = Veins_mariadb.Plain.Make (struct
    let database () =
      match !configured_url with
      | None -> Alcotest.fail "database read before the configuration was loaded"
      | Some url -> Database.create (Label.create "veins_deferred") (Url.create url)
    ;;
  end)

let test_database_read_at_initialize () =
  configured_url := Some "mariadb://configured/x";
  Deferred.Pool.initialize ();
  let label = Label.create "veins_deferred" in
  let registered = Deferred.Pool.find label in
  Deferred.Pool.drop label;
  Lwt.return
    (Alcotest.(check bool)
       "the URL configured before initialize"
       true
       (CCOption.exists
          (fun db -> Url.equal (Database.owner db) (Url.create "mariadb://configured/x"))
          registered))
;;

(* [Pool_options.on_failure] hears of every error a statement raises, once,
   and nothing of [Pool.ping]. *)
let reported : Pool_options.failure list ref = ref []

module Reporting =
  Veins_mariadb.Plain.Make_with_options
    (struct
      let database = Config.database
      let database_pool_size = 2
    end)
    (struct
      let options =
        Pool_options.
          { default with
            reconnect_backoff = 0., 0.
          ; on_failure =
              Some
                (fun failure ->
                  reported := failure :: !reported;
                  Lwt.return_unit)
          }
      ;;
    end)

module Raising =
  Veins_mariadb.Plain.Make_with_options
    (struct
      let database = Config.database
      let database_pool_size = 2
    end)
    (struct
      let options =
        Pool_options.{ default with on_failure = Some (fun _ -> failwith "hook") }
      ;;
    end)

let select_one = Caqti.Templater.static T.(unit -->! int) "SELECT 1"

let test_on_failure () =
  with_server
  @@ fun server ->
  let label = Label.create "veins_on_failure" in
  Reporting.Pool.add (Database.create label (url server));
  Raising.Pool.add (Database.create label (url server));
  let reports name expected =
    let got = !reported in
    reported := [];
    Alcotest.(check int) (name ^ ": reported once") expected (CCList.length got);
    got
  in
  let same_exn name raised { Pool_options.exn; _ } =
    Alcotest.(check bool) (name ^ ": the raised exception") true (exn == raised)
  in
  let%lwt raised =
    expect
      "find"
      (fun () -> Reporting.find (Reporting.label_ctx label) select_one ())
      Fun.id
  in
  CCList.iter
    (fun ({ Pool_options.label = reported_label; request; _ } as failure) ->
       same_exn "find" raised failure;
       Alcotest.(check string)
         "find: label"
         (Label.value label)
         (Label.value reported_label);
       Alcotest.(check bool)
         "find: request"
         true
         (CCOption.exists (fun sql -> CCString.mem ~sub:"SELECT 1" sql) request))
    (reports "find" 1);
  let%lwt raised =
    expect
      "connection_ctx"
      (fun () ->
         Reporting.connection_ctx label (fun ctx -> Reporting.find ctx select_one ()))
      Fun.id
  in
  CCList.iter (same_exn "connection_ctx" raised) (reports "connection_ctx" 1);
  let%lwt raised =
    expect
      "unregistered label"
      (fun () ->
         Reporting.exec
           (Reporting.label_ctx (Label.create "veins_unknown"))
           (Caqti.Templater.static T.(unit -->. unit) "SELECT 1")
           ())
      Fun.id
  in
  CCList.iter (same_exn "unregistered label" raised) (reports "unregistered label" 1);
  let%lwt () =
    match%lwt Reporting.Pool.ping label with
    | Ok () -> Alcotest.fail "ping: expected an error"
    | Error (_ : Error.t) -> Lwt.return_unit
  in
  let (_ : Pool_options.failure list) = reports "ping" 0 in
  (* a request that raises when printed is reported without it, and the
     statement's own error is raised *)
  let unprintable =
    Caqti.Template.Request.create
      Caqti.Template.Request.Static
      T.(unit -->! int)
      (fun _ -> failwith "not printable")
  in
  let%lwt raised =
    expect
      "unprintable request"
      (fun () -> Reporting.find (Reporting.label_ctx label) unprintable ())
      Fun.id
  in
  (match raised with
   | Error.Failed _ -> ()
   | exn ->
     Alcotest.failf "expected the statement's error, got %s" (Printexc.to_string exn));
  CCList.iter
    (fun ({ Pool_options.request; _ } as failure) ->
       same_exn "unprintable request" raised failure;
       Alcotest.(check (option string)) "unprintable request: no request" None request)
    (reports "unprintable request" 1);
  (* parameters are reported, those of a redacted type masked *)
  let login =
    Caqti.Templater.static
      T.(t2 string (redacted string) -->! int)
      "SELECT 1 FROM users WHERE email = ? AND password = ?"
  in
  let%lwt (_ : exn) =
    expect
      "parameters"
      (fun () ->
         Reporting.find (Reporting.label_ctx label) login ("alice@example.com", "hunter2"))
      Fun.id
  in
  CCList.iter
    (fun { Pool_options.params; _ } ->
       let params = CCOption.get_or ~default:"" params in
       Alcotest.(check bool)
         ("plain parameter shown in " ^ params)
         true
         (CCString.mem ~sub:"alice@example.com" params);
       Alcotest.(check bool)
         ("secret masked in " ^ params)
         true
         (CCString.mem ~sub:"#redacted#" params
          && not (CCString.mem ~sub:"hunter2" params)))
    (reports "parameters" 1);
  (* a parameter whose encoder fails is reported without parameters *)
  let rejecting =
    Caqti.Template.Row_type.custom
      ~encode:(fun (_ : int) -> Error "no encoding")
      ~decode:(fun (_ : string) -> Error "no decoding")
      T.string
  in
  let%lwt raised =
    expect
      "unprintable parameters"
      (fun () ->
         Reporting.find
           (Reporting.label_ctx label)
           (Caqti.Templater.static T.(rejecting -->! int) "SELECT ?")
           1)
      Fun.id
  in
  CCList.iter
    (fun ({ Pool_options.request; params; _ } as failure) ->
       same_exn "unprintable parameters" raised failure;
       Alcotest.(check bool)
         "unprintable parameters: request"
         true
         (Option.is_some request);
       Alcotest.(check (option string)) "unprintable parameters: none" None params)
    (reports "unprintable parameters" 1);
  let%lwt () =
    expect
      "failing hook"
      (fun () -> Raising.find (Raising.label_ctx label) select_one ())
      (function
        | Error.Failed _ -> ()
        | exn ->
          Alcotest.failf "expected the statement's error, got %s" (Printexc.to_string exn))
  in
  Reporting.Pool.drop label;
  Raising.Pool.drop label;
  Lwt.return_unit
;;

let () =
  let open Alcotest_lwt in
  let case name speed f = test_case name speed (fun (_ : Lwt_switch.t) () -> f ()) in
  Lwt_main.run
  @@ run
       "Veins offline"
       [ ( "resilience"
         , [ case
               "unreachable database settles every query"
               `Slow
               test_unreachable_database_settles_every_query
           ; case "failed pool retries" `Quick test_failed_pool_retries
           ; case "backoff" `Slow test_backoff
           ; case "on_failure" `Quick test_on_failure
           ; case "Pool.use returns errors" `Quick test_use_returns_errors
           ; case
               "Pool.use timeout hides passwords"
               `Quick
               test_use_timeout_hides_passwords
           ] )
       ; ( "logins"
         , [ case "logins share the owner's pool" `Quick test_logins_share_the_owner_pool
           ; case "registry" `Quick test_registry
           ; case "database read at initialize" `Quick test_database_read_at_initialize
           ; case "strict logins" `Quick test_strict_logins
           ; case "MariaDB error classes" `Quick test_mariadb_permission_errors
           ] )
       ; ( "pools"
         , [ case
               "Connection.test fails without leaking the password"
               `Quick
               test_connection_test_hides_the_password
           ; case
               "Pool.test tracks the connection issue"
               `Quick
               test_database_test_tracks_connection_issue
           ] )
       ]
;;

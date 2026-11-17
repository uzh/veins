(* The connection handling (context type, held connections and transactions,
   after-commit hooks, connection-error classification, background draining,
   retry reset) is ported from the pool tool's database module: the context
   design is Reynir Björnsson's refactoring (uzh/z-pool-tool#647), the
   reconnect fixes come from #624, #637 and #657 there. *)

let src = Logs.Src.create "veins.pools"

module Log = (val Logs.src_log src : Logs.LOG)

module Make_with_options (Config : Pools_sig.ConfigSig) (Options : Pools_sig.OptionsSig) :
  Pools_sig.Sig with module Config = Config = struct
  module Config = Config

  let options = Pool_options.validate Options.options

  type caqti_pool = (Caqti_lwt.connection, Caqti.Error.t) Caqti_lwt_unix.Pool.t

  type connection =
    | Close
    | Open of caqti_pool
    | Fail of Caqti.Error.t

  (* One Caqti pool per label for the owner, plus one per login with a URL of
     its own. Logins without one share the owner's pool ([None]). *)
  module Key = struct
    type t = Entity.Label.t * Entity.Login.t option

    let equal (l1, r1) (l2, r2) =
      Entity.Label.equal l1 l2 && CCOption.equal Entity.Login.equal r1 r2
    ;;

    let hash (label, login) =
      Hashtbl.hash (Entity.Label.value label, CCOption.map Entity.Login.name login)
    ;;

    let show (label, login) =
      match login with
      | None -> Entity.Label.show label
      | Some login ->
        Format.asprintf "%a (login %a)" Entity.Label.pp label Entity.Login.pp login
    ;;

    let login (_, login) = CCOption.value ~default:Entity.Login.owner login
  end

  module Pools_tbl = CCHashtbl.Make (Key)
  module Labels_tbl = CCHashtbl.Make (Entity.Label)

  (* [failures] counts the connection errors since the last statement that
     reached the database, [retry_at] is when the next reconnect may be tried.
     While the one statement that tries it is under way, [probe] holds the last
     error (for everybody else, who fails with it right away) and when to give
     up waiting for that statement. *)
  type entry =
    { key : Key.t
    ; url : Entity.Url.t
    ; required : bool
    ; connection : connection
    ; failures : int
    ; retry_at : float
    ; probe : (Caqti.Error.t * float) option
    }

  let now = Unix.gettimeofday

  (* The first error may be a single connection that went away: reconnect
     right away, for everybody. Only when that fails too is the database
     taken to be gone. *)
  let backs_off failures = failures >= 2

  let backoff failures =
    if backs_off failures
    then (
      let initial, max = options.Pool_options.reconnect_backoff in
      Float.min max (initial *. (2. ** float_of_int (min 30 (failures - 2)))))
    else 0.
  ;;

  let probe_until () =
    match snd options.Pool_options.reconnect_backoff with
    | window when window > 0. -> Some (now () +. window)
    | _ -> None
  ;;

  let databases : Entity.Database.t Labels_tbl.t =
    Labels_tbl.create (max 1 Config.expected_databases)
  ;;

  let pools : entry Pools_tbl.t = Pools_tbl.create (max 1 Config.expected_databases)
  let tags_of_key (label, _) = Logs.Tag.(empty |> add Ctx.label_tag label)
  let raise_error e = raise (Error.Exn e)

  let log_pools () =
    Log.debug (fun m ->
      m
        "Pools: %s"
        (Pools_tbl.to_list pools
         |> CCList.map (fun (key, { connection; _ }) ->
           Format.asprintf
             "%s=%s"
             (Key.show key)
             (match connection with
              | Close -> "closed"
              | Open _ -> "open"
              | Fail _ -> "failed"))
         |> CCString.concat ", "))
  ;;

  (* Say once per login that it runs on the owner's connection. *)
  let shared_logins : unit Pools_tbl.t = Pools_tbl.create 8

  let note_shared_login label login =
    let key = label, Some login in
    if not (Pools_tbl.mem shared_logins key)
    then (
      Pools_tbl.replace shared_logins key ();
      Log.info (fun m ->
        m
          ~tags:(tags_of_key key)
          "Login '%a' has no URL for database '%a': its roles connect as the owner"
          Entity.Login.pp
          login
          Entity.Label.pp
          label))
  ;;

  let forget_shared_logins label =
    Pools_tbl.keys_list shared_logins
    |> CCList.iter (fun ((shared, _) as key) ->
      if Entity.Label.equal shared label then Pools_tbl.remove shared_logins key)
  ;;

  (* The pool [login] connects with. *)
  let resolve label login =
    match Labels_tbl.find_opt databases label with
    | None -> raise_error (Error.Database_not_registered (Entity.Label.value label))
    | Some database ->
      if Entity.Database.has_login database login
      then label, Some login
      else if Entity.Login.is_owner login
      then label, None
      else if Entity.Database.strict_logins database
      then
        raise_error
          (Error.Login_not_configured
             { label = Entity.Label.value label; login = Entity.Login.name login })
      else (
        note_shared_login label login;
        label, None)
  ;;

  (* A statement the database refused. [needs] and [role] only describe it,
     for [Permission_denied]. *)
  let statement_error ?role ?(needs = []) key error =
    let label, _ = key in
    let login = Key.login key in
    if Config.Driver.is_permission_error error
    then
      raise_error
        (Error.Permission_denied
           { label = Entity.Label.value label
           ; login = Entity.Login.name login
           ; role
           ; needs
           ; message = Caqti.Error.show error
           })
    else raise (Error.Failed (Error.failure ?role ~login label error))
  ;;

  (* Both Caqti drivers pin the session to UTC themselves when connecting
     (the suites check it), so there is nothing to send for that. *)
  let post_connect (module Connection : Caqti_lwt.CONNECTION) =
    match options.Pool_options.statement_timeout with
    | None -> Lwt_result.return ()
    | Some (_ : float) as timeout -> Connection.set_statement_timeout timeout
  ;;

  let pool_config =
    let max_size = Config.database_pool_size in
    let max_idle_size = CCOption.map (min max_size) options.Pool_options.max_idle_size in
    let max_idle_age =
      CCOption.flat_map
        (fun seconds -> Mtime.Span.of_float_ns (seconds *. 1e9))
        options.Pool_options.max_idle_age
    in
    Caqti.Pool.Config.create
      ~max_size
      ?max_idle_size
      ~max_idle_age
      ~max_use_count:options.Pool_options.max_use_count
      ()
  ;;

  let connect_pool url =
    Caqti_lwt_unix.connect_pool ~pool_config ~post_connect (Entity.Url.to_connect_uri url)
  ;;

  let failed { key; _ } error =
    Error.Failed (Error.failure ~login:(Key.login key) (fst key) error)
  ;;

  let failing entry error =
    let failures = entry.failures + 1 in
    { entry with
      connection = Fail error
    ; failures
    ; retry_at = now () +. backoff failures
    ; probe = None
    }
  ;;

  (* Caqti connects lazily: this only sets the pool up, and fails for a URL
     no driver can be loaded for. Whether the database answers shows with the
     first statement. *)
  let connect_base entry =
    match connect_pool entry.url with
    | Error error when entry.required -> raise (failed entry error)
    | Error error ->
      Log.warn (fun m ->
        m ~tags:(tags_of_key entry.key) "Failed to connect: %a" Caqti.Error.pp error);
      failing entry error
    | Ok pool -> { entry with connection = Open pool }
  ;;

  (* Never await a drain: Caqti's [Pool.drain] waits for every borrowed
     connection, and wakes only one waiter, so a second drain of the same pool
     never returns (pool tool #637). Every entry is replaced before it is
     drained, so each Caqti pool is drained at most once. *)
  let drain_in_background { key; connection; _ } =
    match connection with
    | Open pool ->
      Lwt.dont_wait
        (fun () -> Caqti_lwt_unix.Pool.drain pool)
        (fun exn ->
           Log.warn (fun m ->
             m "Draining pool '%s' failed: %s" (Key.show key) (Printexc.to_string exn)))
    | Close | Fail _ -> ()
  ;;

  let is_current entry pool =
    match entry.connection with
    | Open current -> CCEqual.physical current pool
    | Close | Fail _ -> false
  ;;

  (* With [~pool], only if that pool is still the registered one: statements
     that were under way on a pool another one already replaced fail later,
     and must leave the replacement alone. *)
  let disconnect_entry ?error ?pool ?(level = Logs.Error) key =
    match Pools_tbl.find_opt pools key with
    | None -> ()
    | Some entry when not (CCOption.for_all (is_current entry) pool) -> ()
    | Some entry ->
      Log.msg level (fun m ->
        m
          ~tags:(tags_of_key key)
          "Disconnect pool '%s'%s"
          (Key.show key)
          (CCOption.map_or
             ~default:""
             (Format.asprintf " with error: %a" Caqti.Error.pp)
             error));
      Pools_tbl.replace
        pools
        key
        (match error with
         | Some error -> failing entry error
         | None ->
           { entry with connection = Close; failures = 0; retry_at = 0.; probe = None });
      drain_in_background entry
  ;;

  (* A statement reached the database through [pool]. *)
  let mark_healthy key pool =
    match Pools_tbl.find_opt pools key with
    | Some entry
      when is_current entry pool && (entry.failures > 0 || Option.is_some entry.probe) ->
      Pools_tbl.replace pools key { entry with failures = 0; retry_at = 0.; probe = None }
    | Some _ | None -> ()
  ;;

  (* The statement trying the reconnect ended without telling whether the
     database is back: let the next ones through. *)
  let release_probe key pool =
    match Pools_tbl.find_opt pools key with
    | Some ({ probe = Some _; _ } as entry) when is_current entry pool ->
      Pools_tbl.replace pools key { entry with probe = None }
    | Some _ | None -> ()
  ;;

  (* Only a broken connection invalidates the pool; a constraint violation or
     a syntax error leaves it alone. *)
  let settle ?role ?needs key pool input =
    let connection_lost error =
      disconnect_entry ~error ~pool key;
      log_pools ()
    in
    match%lwt input with
    | Ok value ->
      mark_healthy key pool;
      Lwt.return value
    | Error error ->
      if Config.Driver.is_connection_error error
      then connection_lost error
      else mark_healthy key pool;
      statement_error ?role ?needs key error
    | exception (Error.Failed { Error.error; _ } as exn)
      when Config.Driver.is_connection_error error ->
      connection_lost error;
      Lwt.reraise exn
    | exception exn ->
      release_probe key pool;
      Lwt.reraise exn
  ;;

  let raise_on_error ?role ?needs key input =
    match%lwt input with
    | Ok value -> Lwt.return value
    | Error error -> statement_error ?role ?needs key error
  ;;

  (* The pool to run a statement on. A pool whose reconnect failed fails
     right away until its backoff is over; then one statement ([~probe]) gets a
     new pool to try, and the others keep failing until that one settled. *)
  let fetch_key ?(probe = true) key =
    let () = log_pools () in
    let connected entry =
      Pools_tbl.replace pools key entry;
      match entry.connection with
      | Open pool -> Lwt.return pool
      | Fail error -> raise (failed entry error)
      | Close -> raise_error (Error.Connection_failed "Failed to connect")
    in
    match Pools_tbl.find_opt pools key with
    | None -> raise_error (Error.Database_not_registered (Entity.Label.value (fst key)))
    | Some entry ->
      (match entry.connection, entry.probe with
       | Open pool, None -> Lwt.return pool
       | Open _, Some (error, until) when probe && now () < until ->
         raise (failed entry error)
       | Open pool, Some (error, _) ->
         if probe
         then
           Pools_tbl.replace
             pools
             key
             { entry with
               probe = CCOption.map (fun until -> error, until) (probe_until ())
             };
         Lwt.return pool
       | Fail error, _ when now () < entry.retry_at -> raise (failed entry error)
       | Fail error, _ ->
         let entry = connect_base entry in
         connected
           (match entry.connection, probe && backs_off entry.failures with
            | Open _, true ->
              { entry with
                probe = CCOption.map (fun until -> error, until) (probe_until ())
              }
            | (Open _ | Close | Fail _), _ -> entry)
       | Close, _ -> connected (connect_base entry))
  ;;

  (* [Pool.use], giving up after [acquire_timeout] without a connection. The
     request for one is never cancelled (Caqti's pool would lose the wake-up
     of the next waiter): once it is served, it returns the connection
     unused. *)
  let use_pool key pool f =
    match options.Pool_options.acquire_timeout with
    | None -> Caqti_lwt_unix.Pool.use f pool
    | Some timeout ->
      let acquired, wake = Lwt.wait () in
      let abandoned = ref false in
      let used =
        Caqti_lwt_unix.Pool.use
          (fun connection ->
             if !abandoned
             then Lwt_result.return None
             else (
               Lwt.wakeup_later wake ();
               let%lwt result = f connection in
               Lwt_result.return (Some result)))
          pool
      in
      let served = Lwt.choose [ acquired; Lwt.map (fun (_ : _ result) -> ()) used ] in
      let timer = Lwt_unix.sleep timeout in
      (match%lwt
         Lwt.choose [ Lwt.map (fun () -> true) served; Lwt.map (fun () -> false) timer ]
       with
       | true ->
         Lwt.cancel timer;
         (match%lwt used with
          | Ok (Some result) -> Lwt.return result
          | Ok None -> raise_error (Error.Connection_failed "Connection abandoned")
          | Error _ as error -> Lwt.return error)
       | false ->
         abandoned := true;
         Lwt.on_failure used (fun (_ : exn) -> ());
         raise_error
           (Error.Connection_failed
              (Format.asprintf
                 "No connection of pool '%s' became free within %gs"
                 (Key.show key)
                 timeout)))
  ;;

  module Pool = struct
    let entries ?(required = false) database =
      let label = Entity.Database.label database in
      let entry key url =
        { key
        ; url
        ; required
        ; connection = Close
        ; failures = 0
        ; retry_at = 0.
        ; probe = None
        }
      in
      entry (label, None) (Entity.Database.owner database)
      :: CCList.map
           (fun login -> entry (label, Some login) (Entity.Database.url database login))
           (Entity.Database.logins database)
    ;;

    let register ?required database =
      Labels_tbl.replace databases (Entity.Database.label database) database;
      CCList.iter
        (fun entry -> Pools_tbl.replace pools entry.key entry)
        (entries ?required database)
    ;;

    let remove label =
      Labels_tbl.remove databases label;
      forget_shared_logins label;
      Pools_tbl.to_list pools
      |> CCList.filter (fun ((pool_label, _), _) -> Entity.Label.equal pool_label label)
      |> CCList.iter (fun (key, entry) ->
        Pools_tbl.remove pools key;
        drain_in_background entry)
    ;;

    let initialize ?(additional_pools = []) () =
      Config.database :: additional_pools
      |> CCList.iter (fun database ->
        if not (Labels_tbl.mem databases (Entity.Database.label database))
        then register ~required:true database)
    ;;

    let add ?required database =
      let label = Entity.Database.label database in
      if Labels_tbl.mem databases label
      then
        Log.warn (fun m ->
          m "Pool '%a' already registered; skipping add" Entity.Label.pp label)
      else register ?required database
    ;;

    let reset ?required database =
      remove (Entity.Database.label database);
      register ?required database
    ;;

    let drop label =
      if Labels_tbl.mem databases label
      then remove label
      else
        Log.info (fun m -> m "Pool '%a' not found; nothing to drop" Entity.Label.pp label)
    ;;

    let clear () =
      let entries = Pools_tbl.values_list pools in
      Pools_tbl.clear pools;
      Pools_tbl.clear shared_logins;
      Labels_tbl.clear databases;
      CCList.iter drain_in_background entries
    ;;

    let find = Labels_tbl.find_opt databases

    let find_all ?(allowed_status = Entity.Status.all) ?(exclude = []) () =
      Labels_tbl.values_list databases
      |> CCList.filter (fun database ->
        CCList.mem
          ~eq:Entity.Status.equal
          (Entity.Database.status database)
          allowed_status
        && not
             (CCList.mem ~eq:Entity.Label.equal (Entity.Database.label database) exclude))
    ;;

    let fetch ?retries:(_ : int option) ?(login = Entity.Login.owner) label =
      fetch_key ~probe:false (resolve label login)
    ;;

    let connect ?(login = Entity.Login.owner) label =
      match resolve label login with
      | exception Error.Exn error -> Error error
      | key ->
        let rec connect entry =
          match entry.connection with
          | Fail error -> Error (Error.Connection_failed (Caqti.Error.show error))
          | Open _ -> Ok ()
          | Close ->
            let entry =
              try connect_base entry with
              | Error.Failed { Error.error; _ } -> { entry with connection = Fail error }
            in
            Pools_tbl.replace pools key entry;
            connect entry
        in
        (match Pools_tbl.find_opt pools key with
         | None -> Error (Error.Database_not_registered (Entity.Label.value label))
         | Some entry -> connect entry)
    ;;

    let ping ?(login = Entity.Login.owner) label =
      Lwt.catch
        (fun () ->
           let key = resolve label login in
           let%lwt pool = fetch_key key in
           let%lwt () =
             use_pool key pool (fun (_ : Caqti_lwt.connection) -> Lwt_result.return ())
             |> settle key pool
           in
           Lwt_result.return ())
        (function
          | Error.Exn error -> Lwt_result.fail error
          | Error.Failed { Error.error; _ } ->
            Lwt_result.fail (Error.Connection_failed (Caqti.Error.show error))
          | exn -> Lwt.reraise exn)
    ;;

    let same_urls a b =
      let open Entity in
      let logins database =
        Database.logins database
        |> CCList.sort Login.compare
        |> CCList.map (fun login -> login, Database.url database login)
      in
      Url.equal (Database.owner a) (Database.owner b)
      && CCList.equal (CCPair.equal Login.equal Url.equal) (logins a) (logins b)
    ;;

    (* A test tells about the registered database only if that is the one
       tested, not when other URLs were tried for its label. *)
    let track_connection_issue database result =
      let label = Entity.Database.label database in
      let set status registered =
        Labels_tbl.replace databases label (Entity.Database.with_status status registered)
      in
      match Labels_tbl.find_opt databases label with
      | Some registered when same_urls registered database ->
        (match Entity.Database.status registered, result with
         | Entity.Status.Active, Error error ->
           Log.warn (fun m ->
             m
               ~tags:(tags_of_key (label, None))
               "Connection test failed, status is now %a: %a"
               Entity.Status.pp
               Entity.Status.ConnectionIssue
               Error.pp
               error);
           set Entity.Status.ConnectionIssue registered
         | Entity.Status.ConnectionIssue, Ok () ->
           Log.info (fun m ->
             m
               ~tags:(tags_of_key (label, None))
               "Connection test succeeded, status is %a again"
               Entity.Status.pp
               Entity.Status.Active);
           set Entity.Status.Active registered
         | ( Entity.Status.(
               ( Active
               | ConnectionIssue
               | Disabled
               | Maintenance
               | MigrationsConnectionIssue
               | MigrationsFailed
               | MigrationsPending ))
           , (Ok () | Error (_ : Error.t)) ) -> ())
      | Some (_ : Entity.Database.t) | None -> ()
    ;;

    let test database =
      let urls =
        Entity.Database.owner database
        :: CCList.map (Entity.Database.url database) (Entity.Database.logins database)
      in
      let%lwt result =
        Lwt_list.fold_left_s
          (fun result url ->
             match result with
             | Ok () -> Connection.test ~post_connect url
             | Error (_ : Error.t) -> Lwt.return result)
          (Ok ())
          urls
      in
      track_connection_issue database result;
      Lwt.return result
    ;;

    let disconnect ?error ?login label =
      match login with
      | Some login -> disconnect_entry ?error (resolve label login)
      | None ->
        Pools_tbl.keys_list pools
        |> CCList.filter (fun (pool_label, _) -> Entity.Label.equal pool_label label)
        |> CCList.iter (disconnect_entry ?error)
    ;;
  end

  let role_name ctx = Entity.Role.name (Ctx.role ctx)

  (* Names the login in errors of a held connection. It must not raise: the
     connection stays usable after its database was dropped. *)
  let held_key ctx =
    let label = Ctx.label ctx in
    let login = Entity.Role.login (Ctx.role ctx) in
    try resolve label login with
    | Error.Exn (Error.Database_not_registered _ | Error.Login_not_configured _) ->
      label, if Entity.Login.is_owner login then None else Some login
  ;;

  (* Run [f] on a connection of [ctx]: the held one, serialised by its mutex,
     or a fresh one from the pool. *)
  let run ~needs ctx f =
    let role = role_name ctx in
    let needs = Entity.Need.names needs in
    match Ctx.Internal.connection ctx, Ctx.Internal.mutex ctx with
    | Some connection, Some mutex ->
      Lwt_mutex.with_lock mutex (fun () ->
        f connection |> raise_on_error ~role ~needs (held_key ctx))
    | _ ->
      let key = resolve (Ctx.label ctx) (Entity.Role.login (Ctx.role ctx)) in
      let%lwt pool = fetch_key key in
      use_pool key pool (fun connection -> f (Connection.fixed connection))
      |> settle ~role ~needs key pool
  ;;

  let query ~needs ctx f = run ~needs ctx f

  let request ctx request f =
    run ~needs:(Request.needs request) ctx (fun connection ->
      f connection (Request.caqti request))
  ;;

  let exec ctx req input =
    request ctx req (fun (module Connection : Caqti_lwt.CONNECTION) req ->
      Connection.exec req input)
  ;;

  let collect ctx req input =
    request ctx req (fun (module Connection : Caqti_lwt.CONNECTION) req ->
      Connection.collect_list req input)
  ;;

  let find ctx req input =
    request ctx req (fun (module Connection : Caqti_lwt.CONNECTION) req ->
      Connection.find req input)
  ;;

  let find_opt ctx req input =
    request ctx req (fun (module Connection : Caqti_lwt.CONNECTION) req ->
      Connection.find_opt req input)
  ;;

  let exec_each fns connection =
    CCList.fold_left
      (fun acc fn -> Lwt_result.bind acc (fun () -> fn connection))
      (Lwt_result.return ())
      fns
  ;;

  (* The connection may come from elsewhere than veins: fix it (again). *)
  let connection_transaction connection fn =
    let (module Connection : Caqti_lwt.CONNECTION) = Connection.fixed connection in
    Connection.with_transaction fn
  ;;

  let populate ~needs ctx table columns row_type rows =
    query ~needs ctx (fun (module Connection : Caqti_lwt.CONNECTION) ->
      Connection.populate ~table ~columns row_type (Caqti_lwt.Stream.of_list rows)
      |> Lwt.map Caqti.Error.uncongested)
  ;;

  let transaction ?(setup = []) ?(cleanup = []) ~needs ctx fn =
    query ~needs ctx (fun connection ->
      let open Lwt_result.Syntax in
      let fn' () =
        let* () = exec_each setup connection in
        let* result = fn connection in
        let* () = exec_each cleanup connection in
        Lwt_result.return result
      in
      if Ctx.is_transaction ctx
      then fn' ()
      else (
        let (module Connection : Caqti_lwt.CONNECTION) = connection in
        Connection.with_transaction fn'))
  ;;

  let transaction_iter ~needs ctx fns = transaction ~needs ctx (exec_each fns)
  let label_ctx ?tags ~role label = Ctx.Internal.label_ctx ?tags ~role label

  (* Borrow one connection for [f]. Connection errors, also those raised from
     within [f], drop the pool so the next statement reconnects. *)
  let with_pool_connection ~role label f =
    let key = resolve label (Entity.Role.login role) in
    let role = Entity.Role.name role in
    let%lwt pool = fetch_key key in
    use_pool key pool (fun connection -> f (Connection.fixed connection) |> Lwt_result.ok)
    |> settle ~role key pool
  ;;

  let connection_ctx ?tags ~role label f =
    with_pool_connection ~role label (fun connection ->
      f (Ctx.Internal.connection_ctx ?tags ~role label connection))
  ;;

  let in_transaction (type g) (ctx : (Ctx.transaction, g) Ctx.t) f =
    let role = role_name ctx in
    let key = held_key ctx in
    let connection =
      CCOption.get_exn_or
        "transaction context without connection"
        (Ctx.Internal.connection ctx)
    in
    let (module Connection : Caqti_lwt.CONNECTION) = connection in
    let mutex =
      CCOption.get_exn_or "transaction context without mutex" (Ctx.Internal.mutex ctx)
    in
    let locked f = Lwt_mutex.with_lock mutex f in
    let rollback exn =
      let%lwt () =
        match%lwt locked Connection.rollback with
        | Ok () -> Lwt.return (Log.debug (fun m -> m ~tags:(Ctx.tags ctx) "Rolled back"))
        | Error error ->
          Lwt.return
            (Log.warn (fun m ->
               m ~tags:(Ctx.tags ctx) "Rollback failed: %a" Caqti.Error.pp error))
      in
      Lwt.reraise exn
    in
    let%lwt () = locked Connection.start |> raise_on_error ~role key in
    let%lwt result = Lwt.catch (fun () -> f ctx) rollback in
    let%lwt () =
      Lwt.catch (fun () -> locked Connection.commit |> raise_on_error ~role key) rollback
    in
    Ctx.Internal.run_after_commit ctx ~on_error:(fun exn ->
      Log.err (fun m ->
        m ~tags:(Ctx.tags ctx) "After-commit hook failed: %s" (Printexc.to_string exn)));
    Lwt.return result
  ;;

  let transaction_ctx ?tags ~role label f =
    with_pool_connection ~role label (fun connection ->
      in_transaction (Ctx.Internal.transaction_ctx ?tags ~role label connection) f)
  ;;

  let with_transaction
        (type maybe_txn g a)
        (ctx : (maybe_txn, g) Ctx.t)
        (f : (Ctx.transaction, g) Ctx.t -> a Lwt.t)
    : a Lwt.t
    =
    let tags = Ctx.tags ctx in
    let role = Ctx.role ctx in
    let label = Ctx.label ctx in
    match Ctx.txn ctx with
    | Ctx.Yes -> f ctx
    | Ctx.No ->
      (match Ctx.Internal.connection ctx with
       | Some connection ->
         in_transaction
           (Ctx.Internal.transaction_ctx
              ~tags
              ~role
              ?mutex:(Ctx.Internal.mutex ctx)
              label
              connection)
           f
       | None -> transaction_ctx ~tags ~role label f)
  ;;
end

module Make (Config : Pools_sig.ConfigSig) =
  Make_with_options
    (Config)
    (struct
      let options = Pool_options.default
    end)

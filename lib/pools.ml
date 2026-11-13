(* The connection handling (context type, held connections and transactions,
   after-commit hooks, connection-error classification, background draining,
   retry reset) is ported from the pool tool's database module: the context
   design is Reynir Björnsson's refactoring (uzh/z-pool-tool#647), the
   reconnect fixes come from #624, #637 and #657 there. *)

let src = Logs.Src.create "veins.pools"

module Log = (val Logs.src_log src : Logs.LOG)

module Make (Config : Pools_sig.ConfigSig) : Pools_sig.Sig with module Config = Config =
struct
  module Config = Config

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

  type entry =
    { key : Key.t
    ; url : Entity.Url.t
    ; required : bool
    ; connection : connection
    ; n_retries : int
    }

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

  (* The pool [login] connects with. *)
  let resolve label login =
    match Labels_tbl.find_opt databases label with
    | None -> raise_error (Error.Database_not_registered (Entity.Label.value label))
    | Some database ->
      if Entity.Database.has_login database login then label, Some login else label, None
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

  (* Both render their SQL from the dialect of the connection they run on. *)
  let set_utc =
    Dialect.request
      Caqti.Template.Request.Static
      Caqti.Templater.T.(unit -->. unit)
      Dialect.set_utc
  ;;

  let restore_autocommit =
    Dialect.request
      Caqti.Template.Request.Static
      Caqti.Templater.T.(unit -->. unit)
      (fun kind -> Dialect.restore_autocommit kind |> CCOption.get_or ~default:"")
  ;;

  let post_connect (module Connection : Caqti_lwt.CONNECTION) = Connection.exec set_utc ()

  (* Never use the driver's [rollback] (or caqti's [with_transaction]) alone,
     see [Dialect.restore_autocommit]. *)
  let rollback (module Connection : Caqti_lwt.CONNECTION) =
    let%lwt rolled_back = Connection.rollback () in
    let%lwt restored =
      match Dialect.restore_autocommit (Dialect.kind Connection.dialect) with
      | None -> Lwt_result.return ()
      | Some (_ : string) -> Connection.exec restore_autocommit ()
    in
    Lwt.return
      (match rolled_back with
       | Error _ as error -> error
       | Ok () -> restored)
  ;;

  (* caqti-driver-postgresql connects with libpq's blocking PQconnectdb, which holds up
     the whole Lwt loop until the handshake is done, and libpq waits indefinitely by
     default. Bound it unless the URL sets its own connect_timeout. *)
  let with_connect_timeout uri =
    match Uri.scheme uri with
    | Some ("postgresql" | "postgres")
      when Option.is_none (Uri.get_query_param uri "connect_timeout") ->
      Uri.add_query_param' uri ("connect_timeout", "5")
    | Some _ | None -> uri
  ;;

  let connect_pool url =
    let pool_config = Caqti.Pool.Config.create ~max_size:Config.database_pool_size () in
    Caqti_lwt_unix.connect_pool
      ~pool_config
      ~post_connect
      (Entity.Url.to_uri url |> with_connect_timeout)
  ;;

  let failed { key; _ } error =
    Error.Failed (Error.failure ~login:(Key.login key) (fst key) error)
  ;;

  let connect_base ?(retries = 2) entry =
    match CCResult.retry retries (fun () -> connect_pool entry.url) with
    | Error [] -> raise_error (Error.Connection_failed "Failed to connect: empty error")
    | Error (error :: _) when entry.required -> raise (failed entry error)
    | Error (error :: _ as errors) ->
      Log.warn (fun m ->
        m
          ~tags:(tags_of_key entry.key)
          "Failed to connect: %s"
          (CCString.concat "; " (CCList.map Caqti.Error.show errors)));
      { entry with connection = Fail error }
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

  let disconnect_entry ?error ?(level = Logs.Error) key =
    match Pools_tbl.find_opt pools key with
    | None -> ()
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
      let connection =
        match error with
        | Some error -> Fail error
        | None -> Close
      in
      Pools_tbl.replace pools key { entry with connection };
      drain_in_background entry
  ;;

  (* Only a broken connection invalidates the pool; a constraint violation or
     a syntax error leaves it alone. *)
  let raise_caqti_error ?role ?needs key input =
    match%lwt input with
    | Ok value -> Lwt.return value
    | Error error ->
      if Config.Driver.is_connection_error error
      then (
        disconnect_entry ~error key;
        log_pools ());
      statement_error ?role ?needs key error
  ;;

  let raise_on_error ?role ?needs key input =
    match%lwt input with
    | Ok value -> Lwt.return value
    | Error error -> statement_error ?role ?needs key error
  ;;

  let rec fetch_key ?(retries = 2) key =
    let () = log_pools () in
    match Pools_tbl.find_opt pools key with
    | None -> raise_error (Error.Database_not_registered (Entity.Label.value (fst key)))
    | Some ({ n_retries; _ } as entry) ->
      (match entry.connection with
       | Fail error when n_retries >= retries ->
         (* Give up for this call, but reset the counter, so the next call
            tries to reconnect again (pool tool #624). *)
         Pools_tbl.replace pools key { entry with n_retries = 0 };
         raise (failed entry error)
       | Fail _ ->
         Pools_tbl.replace
           pools
           key
           { (connect_base entry) with n_retries = entry.n_retries + 1 };
         fetch_key ~retries key
       | Close ->
         Pools_tbl.replace pools key (connect_base entry);
         fetch_key ~retries key
       | Open pool ->
         if n_retries > 0 then Pools_tbl.replace pools key { entry with n_retries = 0 };
         Lwt.return pool)
  ;;

  module Pool = struct
    let entries ?(required = false) database =
      let label = Entity.Database.label database in
      let entry key url = { key; url; required; connection = Close; n_retries = 0 } in
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

    let fetch ?retries ?(login = Entity.Login.owner) label =
      fetch_key ?retries (resolve label login)
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
    | Error.Exn (Error.Database_not_registered _) ->
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
      Caqti_lwt_unix.Pool.use f pool |> raise_caqti_error ~role ~needs key
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

  let populate ~needs ctx table columns row_type rows =
    query ~needs ctx (fun (module Connection : Caqti_lwt.CONNECTION) ->
      Connection.populate ~table ~columns row_type (Caqti_lwt.Stream.of_list rows)
      |> Lwt.map Caqti.Error.uncongested)
  ;;

  let exec_each fns connection =
    CCList.fold_left
      (fun acc fn -> Lwt_result.bind acc (fun () -> fn connection))
      (Lwt_result.return ())
      fns
  ;;

  let connection_transaction ((module Connection : Caqti_lwt.CONNECTION) as connection) fn
    =
    let open Lwt_result.Syntax in
    let fail_after_rollback error =
      let%lwt (_ : (unit, Caqti.Error.t) result) = rollback connection in
      Lwt_result.fail error
    in
    let* () = Connection.start () in
    match%lwt fn () with
    | Ok result ->
      (match%lwt Connection.commit () with
       | Ok () -> Lwt_result.return result
       | Error error -> fail_after_rollback error)
    | Error error -> fail_after_rollback error
    | exception exn ->
      let%lwt (_ : (unit, Caqti.Error.t) result) = rollback connection in
      Lwt.reraise exn
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
      if Ctx.is_transaction ctx then fn' () else connection_transaction connection fn')
  ;;

  let transaction_iter ~needs ctx fns = transaction ~needs ctx (exec_each fns)
  let label_ctx ?tags ~role label = Ctx.Internal.label_ctx ?tags ~role label

  (* Borrow one connection for [f]. Connection errors, also those raised from
     within [f], drop the pool so the next statement reconnects. *)
  let with_pool_connection ~role label f =
    let key = resolve label (Entity.Role.login role) in
    let role = Entity.Role.name role in
    let%lwt pool = fetch_key key in
    try%lwt
      match%lwt Caqti_lwt_unix.Pool.use (fun c -> f c |> Lwt_result.ok) pool with
      | Ok value -> Lwt.return value
      | Error error -> raise_caqti_error ~role key (Lwt.return (Error error))
    with
    | Error.Failed { Error.error; _ } as exn when Config.Driver.is_connection_error error
      ->
      disconnect_entry ~error key;
      log_pools ();
      Lwt.reraise exn
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
        match%lwt locked (fun () -> rollback connection) with
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

(* The connection handling (context type, held connections and transactions,
   after-commit hooks, connection-error classification, background draining,
   retry reset) is ported from the pool tool's database module: the context
   design is Reynir Björnsson's refactoring (uzh/z-pool-tool#647), the
   reconnect fixes come from #624, #637 and #657 there. *)

open Caqti_request.Infix

let src = Logs.Src.create "veins.pools"

module Log = (val Logs.src_log src : Logs.LOG)

module Make (Config : Pools_sig.ConfigSig) : Pools_sig.Sig with module Config = Config =
struct
  module Config = Config

  type caqti_pool = (Caqti_lwt.connection, Caqti_error.t) Caqti_lwt_unix.Pool.t

  type connection =
    | Close
    | Open of caqti_pool
    | Fail of Caqti_error.t

  (* One Caqti pool per label ([Main]) or per label and role ([Multiple]). *)
  module Key = struct
    type t = Entity.Label.t * string option

    let equal (l1, r1) (l2, r2) =
      Entity.Label.equal l1 l2 && CCOption.equal CCString.equal r1 r2
    ;;

    let hash (label, role) = Hashtbl.hash (Entity.Label.value label, role)

    let show (label, role) =
      match role with
      | None -> Entity.Label.show label
      | Some role -> Format.asprintf "%a (role %s)" Entity.Label.pp label role
    ;;
  end

  module Pools_tbl = CCHashtbl.Make (Key)
  module Labels_tbl = CCHashtbl.Make (Entity.Label)

  type entry =
    { key : Key.t
    ; role : Entity.Role.t option
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

  (* The pool [role] runs on, and the capabilities it has ([None]: all). *)
  let resolve ?role label =
    let label_value = Entity.Label.value label in
    match Labels_tbl.find_opt databases label with
    | None -> raise_error (Error.Database_not_registered label_value)
    | Some database ->
      (match Entity.Database.pool database, role with
       | Entity.Database.Main _, None -> (label, None), None
       | Entity.Database.Main _, Some role ->
         (match Entity.Database.role_policy database with
          | Entity.Database.Fallback -> (label, None), None
          | Entity.Database.Strict ->
            raise_error
              (Error.Role_not_configured
                 { label = label_value; role = Entity.Role.value role }))
       | Entity.Database.Multiple _, None -> raise_error (Error.Role_required label_value)
       | Entity.Database.Multiple _, Some role ->
         (match Entity.Database.find_role database role with
          | None ->
            raise_error
              (Error.Role_not_configured
                 { label = label_value; role = Entity.Role.value role })
          | Some role ->
            (label, Some (Entity.Role.value role)), Some (Entity.Role.capabilities role)))
  ;;

  (* Fails before anything is sent when [needs] exceeds the role's rights. A
     held connection checks against the rights resolved when it was opened, so
     it keeps working after its database was dropped. *)
  let authorize needs ctx =
    let label = Ctx.label ctx in
    let role = Ctx.role ctx in
    let capabilities =
      match Ctx.held_capabilities ctx with
      | Some capabilities -> capabilities
      | None -> snd (resolve ?role label)
    in
    match capabilities with
    | None -> ()
    | Some capabilities ->
      let missing = Entity.Capability.Set.diff needs capabilities in
      if not (Entity.Capability.Set.is_empty missing)
      then
        raise_error
          (Error.Insufficient_capabilities
             { label = Entity.Label.value label
             ; role = CCOption.map Entity.Role.value role
             ; missing =
                 Entity.Capability.Set.elements missing
                 |> CCList.map Entity.Capability.name
             })
  ;;

  let session_setup_requests =
    CCList.map
      (fun sql -> (Caqti_type.unit ->. Caqti_type.unit) sql)
      Config.Dialect.session_setup
  ;;

  let exec_requests (module Connection : Caqti_lwt.CONNECTION) requests =
    CCList.fold_left
      (fun acc request -> Lwt_result.bind acc (fun () -> Connection.exec request ()))
      (Lwt_result.return ())
      requests
  ;;

  let post_connect connection = exec_requests connection session_setup_requests

  let after_rollback_requests =
    CCList.map
      (fun sql -> (Caqti_type.unit ->. Caqti_type.unit) sql)
      Config.Dialect.after_rollback
  ;;

  (* Never use the driver's [rollback] (or caqti's [with_transaction]) alone,
     see [Dialect.Sig.after_rollback]. *)
  let rollback ((module Connection : Caqti_lwt.CONNECTION) as connection) =
    let%lwt rolled_back = Connection.rollback () in
    let%lwt restored = exec_requests connection after_rollback_requests in
    Lwt.return
      (match rolled_back with
       | Error _ as error -> error
       | Ok () -> restored)
  ;;

  let connect_pool url =
    let pool_config = Caqti_pool_config.create ~max_size:Config.database_pool_size () in
    Caqti_lwt_unix.connect_pool ~pool_config ~post_connect (Entity.Url.to_uri url)
  ;;

  let failed { key = label, _; role; _ } error =
    Error.Failed (Error.failure ?role label error)
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
          (CCString.concat "; " (CCList.map Caqti_error.show errors)));
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
             (Format.asprintf " with error: %a" Caqti_error.pp)
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
  let raise_caqti_error key role input =
    match%lwt input with
    | Ok value -> Lwt.return value
    | Error error ->
      if Config.Dialect.is_connection_error error
      then (
        disconnect_entry ~error key;
        log_pools ());
      raise (Error.Failed (Error.failure ?role (fst key) error))
  ;;

  let raise_on_error label role input =
    match%lwt input with
    | Ok value -> Lwt.return value
    | Error error -> raise (Error.Failed (Error.failure ?role label error))
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
      let entry key role url =
        { key; role; url; required; connection = Close; n_retries = 0 }
      in
      match Entity.Database.pool database with
      | Entity.Database.Main url -> [ entry (label, None) None url ]
      | Entity.Database.Multiple roles ->
        CCList.map
          (fun (role, url) ->
             entry (label, Some (Entity.Role.value role)) (Some role) url)
          roles
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

    let fetch ?retries ?role label = fetch_key ?retries (fst (resolve ?role label))

    let connect ?role label =
      match resolve ?role label with
      | exception Error.Exn error -> Error error
      | key, _ ->
        let rec connect entry =
          match entry.connection with
          | Fail error -> Error (Error.Connection_failed (Caqti_error.show error))
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

    let disconnect ?error ?role label =
      match role with
      | Some role -> disconnect_entry ?error (fst (resolve ~role label))
      | None ->
        Pools_tbl.keys_list pools
        |> CCList.filter (fun (pool_label, _) -> Entity.Label.equal pool_label label)
        |> CCList.iter (disconnect_entry ?error)
    ;;
  end

  (* Run [f] on a connection of [ctx]: the held one, serialised by its mutex,
     or a fresh one from the pool. *)
  let run ctx f =
    let label = Ctx.label ctx in
    let role = Ctx.role ctx in
    match Ctx.connection ctx, Ctx.mutex ctx with
    | Some connection, Some mutex ->
      Lwt_mutex.with_lock mutex (fun () -> f connection |> raise_on_error label role)
    | _ ->
      let key, _ = resolve ?role label in
      let%lwt pool = fetch_key key in
      Caqti_lwt_unix.Pool.use f pool |> raise_caqti_error key role
  ;;

  let query ~needs ctx f =
    authorize (Entity.Capability.Set.of_list needs) ctx;
    run ctx f
  ;;

  let request ctx request f =
    authorize (Request.needs request) ctx;
    run ctx (fun connection -> f connection (Request.caqti request))
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
      |> Lwt.map Caqti_error.uncongested)
  ;;

  let exec_each fns connection =
    CCList.fold_left
      (fun acc fn -> Lwt_result.bind acc (fun () -> fn connection))
      (Lwt_result.return ())
      fns
  ;;

  let transaction ?(setup = []) ?(cleanup = []) ~needs ctx fn =
    query ~needs ctx (fun ((module Connection : Caqti_lwt.CONNECTION) as connection) ->
      let open Lwt_result.Syntax in
      let fn' () =
        let* () = exec_each setup connection in
        let* result = fn connection in
        let* () = exec_each cleanup connection in
        Lwt_result.return result
      in
      let fail_after_rollback error =
        let%lwt (_ : (unit, Caqti_error.t) result) = rollback connection in
        Lwt_result.fail error
      in
      if Ctx.is_transaction ctx
      then fn' ()
      else
        let* () = Connection.start () in
        match%lwt fn' () with
        | Ok result ->
          (match%lwt Connection.commit () with
           | Ok () -> Lwt_result.return result
           | Error error -> fail_after_rollback error)
        | Error error -> fail_after_rollback error
        | exception exn ->
          let%lwt (_ : (unit, Caqti_error.t) result) = rollback connection in
          Lwt.reraise exn)
  ;;

  let transaction_iter ~needs ctx fns = transaction ~needs ctx (exec_each fns)
  let label_ctx ?tags ?role label = Ctx.label_ctx ?tags ?role label

  (* Borrow one connection for [f]. Connection errors, also those raised from
     within [f], drop the pool so the next statement reconnects. *)
  let with_pool_connection ?role label f =
    let key, capabilities = resolve ?role label in
    let%lwt pool = fetch_key key in
    try%lwt
      match%lwt
        Caqti_lwt_unix.Pool.use (fun c -> f ~capabilities c |> Lwt_result.ok) pool
      with
      | Ok value -> Lwt.return value
      | Error error -> raise_caqti_error key role (Lwt.return (Error error))
    with
    | Error.Failed { Error.error; _ } as exn when Config.Dialect.is_connection_error error
      ->
      disconnect_entry ~error key;
      log_pools ();
      Lwt.reraise exn
  ;;

  let connection_ctx ?tags ?role label f =
    with_pool_connection ?role label (fun ~capabilities connection ->
      f (Ctx.connection_ctx ?tags ?role ~capabilities label connection))
  ;;

  let in_transaction (ctx : Ctx.transaction Ctx.t) f =
    let label = Ctx.label ctx in
    let role = Ctx.role ctx in
    let connection =
      CCOption.get_exn_or "transaction context without connection" (Ctx.connection ctx)
    in
    let (module Connection : Caqti_lwt.CONNECTION) = connection in
    let mutex = CCOption.get_exn_or "transaction context without mutex" (Ctx.mutex ctx) in
    let locked f = Lwt_mutex.with_lock mutex f in
    let rollback exn =
      let%lwt () =
        match%lwt locked (fun () -> rollback connection) with
        | Ok () -> Lwt.return (Log.debug (fun m -> m ~tags:(Ctx.tags ctx) "Rolled back"))
        | Error error ->
          Lwt.return
            (Log.warn (fun m ->
               m ~tags:(Ctx.tags ctx) "Rollback failed: %a" Caqti_error.pp error))
      in
      Lwt.reraise exn
    in
    let%lwt () = locked Connection.start |> raise_on_error label role in
    let%lwt result = Lwt.catch (fun () -> f ctx) rollback in
    let%lwt () =
      Lwt.catch (fun () -> locked Connection.commit |> raise_on_error label role) rollback
    in
    Ctx.After_commit.run (Ctx.on_commit ctx) ~on_error:(fun exn ->
      Log.err (fun m ->
        m ~tags:(Ctx.tags ctx) "After-commit hook failed: %s" (Printexc.to_string exn)));
    Lwt.return result
  ;;

  let transaction_ctx ?tags ?role label f =
    with_pool_connection ?role label (fun ~capabilities connection ->
      in_transaction (Ctx.transaction_ctx ?tags ?role ~capabilities label connection) f)
  ;;

  let with_transaction
        (type maybe_txn a)
        (ctx : maybe_txn Ctx.t)
        (f : Ctx.transaction Ctx.t -> a Lwt.t)
    : a Lwt.t
    =
    let tags = Ctx.tags ctx in
    let role = Ctx.role ctx in
    let label = Ctx.label ctx in
    match Ctx.txn ctx with
    | Ctx.Yes -> f ctx
    | Ctx.No ->
      (match Ctx.connection ctx with
       | Some connection ->
         let capabilities =
           Ctx.held_capabilities ctx
           |> CCOption.get_exn_or "held connection without rights"
         in
         in_transaction
           (Ctx.transaction_ctx
              ~tags
              ?role
              ?mutex:(Ctx.mutex ctx)
              ~capabilities
              label
              connection)
           f
       | None -> transaction_ctx ~tags ?role label f)
  ;;
end

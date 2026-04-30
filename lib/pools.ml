open Caqti_request.Infix

let src = Logs.Src.create "veins.pools"

module Log = (val Logs.src_log src : Logs.LOG)

module Make (Config : Pools_sig.ConfigSig) : Pools_sig.Sig with module Config = Config =
struct
  module Config = Config

  type caqti_pool = (Caqti_lwt.connection, Caqti_error.t) Caqti_lwt_unix.Pool.t

  type connection_state =
    | Close
    | Open of caqti_pool
    | Fail of string

  module Pool_entry = struct
    type t =
      { database : Entity.Database.t
      ; required : bool
      ; role : Entity.Role.t option
      ; connection : connection_state
      ; n_retries : int
      }

    let make ?(required = false) ?role database =
      { database; required; role; connection = Close; n_retries = 0 }
    ;;

    let database_label { database; _ } = Entity.Database.label database
    let database_url { database; _ } = Entity.Database.url database
    let increment_retry p = { p with n_retries = p.n_retries + 1 }
    let reset_retry p = { p with n_retries = 0 }
    let mark_fail msg p = { p with connection = Fail msg }
    let mark_close p = { p with connection = Close }

    let make_caqti_pool url =
      let pool_config = Caqti_pool_config.create ~max_size:Config.database_pool_size () in
      url |> Entity.Url.to_uri |> Caqti_lwt_unix.connect_pool ~pool_config
    ;;

    let raise_connection_failed msg = raise (Error.Exn (Error.Connection_failed msg))

    let make_connection_error_message entry err =
      Format.asprintf
        "Failed to connect to '%s': %a"
        (Entity.Label.show (database_label entry))
        Caqti_error.pp
        err
    ;;

    let connect_base ?(retries = 2) ({ required; _ } as entry) =
      let attempt () = entry |> database_url |> make_caqti_pool in
      let result = CCResult.retry retries attempt in
      match result with
      | Error [] -> raise_connection_failed "Failed to connect: empty error list"
      | Error (err :: _) when required ->
        raise_connection_failed
          (Format.asprintf
             "Required database '%s' unavailable: %a"
             (Entity.Label.show (database_label entry))
             Caqti_error.pp
             err)
      | Error (err :: _) ->
        let msg = make_connection_error_message entry err in
        Log.warn (fun m -> m "%s" msg);
        { entry with connection = Fail msg }
      | Ok pool -> { entry with connection = Open pool }
    ;;
  end

  (* Cache keyed by (Label.t * Role.t option) so role pools are stored
     independently of the primary pool without any string mangling. *)
  module Cache = struct
    module Key = struct
      type t = Entity.Label.t * Entity.Role.t option

      let equal (l1, r1) (l2, r2) =
        Entity.Label.equal l1 l2
        &&
        match r1, r2 with
        | None, None -> true
        | Some a, Some b -> Entity.Role.equal a b
        | _ -> false
      ;;

      let hash (l, r) =
        let lh = Entity.Label.hash l in
        let rh =
          match r with
          | None -> 0
          | Some role -> Hashtbl.hash (Entity.Role.value role)
        in
        lh lxor (rh * 2654435761)
      ;;
    end

    module Tbl = CCHashtbl.Make (Key)

    let pools : Pool_entry.t Tbl.t = Tbl.create (max 1 Config.expected_databases)
    let clear () = Tbl.clear pools
    let find_opt label role = Tbl.find_opt pools (label, role)
    let remove label role = Tbl.remove pools (label, role)

    let replace ({ Pool_entry.database; role; _ } as entry) =
      Tbl.replace pools (Entity.Database.label database, role) entry
    ;;

    let all () = Tbl.values_list pools
  end

  module Pool = struct
    let drain_if_open { Pool_entry.connection; _ } =
      match connection with
      | Open pool ->
        let%lwt () = Caqti_lwt_unix.Pool.drain pool in
        Lwt.return_unit
      | Close | Fail _ -> Lwt.return_unit
    ;;

    (* Register the primary entry and one entry per role. *)
    let register_database ?required database =
      match Entity.Database.pool database with
      | Entity.Database.Main _ ->
        Pool_entry.make ?required database |> Pool_entry.connect_base |> Cache.replace
      | Entity.Database.Multiple roles ->
        CCList.iter
          (fun (role, url) ->
             let role_db =
               Entity.Database.create
                 (Entity.Database.label database)
                 (Entity.Database.Main url)
             in
             Pool_entry.make ?required ~role role_db
             |> Pool_entry.connect_base
             |> Cache.replace)
          roles
    ;;

    let initialize ?(additional_pools = []) () =
      CCList.iter
        (fun db ->
           match Cache.find_opt (Entity.Database.label db) None with
           | Some _ -> ()
           | None -> register_database ~required:true db)
        (Config.database :: additional_pools)
    ;;

    let add ?required database =
      let label = Entity.Database.label database in
      match Cache.find_opt label None with
      | Some _ ->
        Log.warn (fun m ->
          m "Pool '%s' already registered; skipping add" (Entity.Label.show label))
      | None -> register_database ?required database
    ;;

    (* Drop the primary pool and all role pools for [label]. *)
    let drop label =
      let role_entries =
        CCList.filter
          (fun entry ->
             Entity.Label.equal (Pool_entry.database_label entry) label
             && Option.is_some entry.Pool_entry.role)
          (Cache.all ())
      in
      let%lwt () =
        Lwt_list.iter_s
          (fun entry ->
             let%lwt () = drain_if_open entry in
             Cache.remove label entry.Pool_entry.role;
             Lwt.return_unit)
          role_entries
      in
      match Cache.find_opt label None with
      | None ->
        Log.info (fun m ->
          m "Pool '%s' not found; nothing to drop" (Entity.Label.show label));
        Lwt.return_unit
      | Some entry ->
        let%lwt () = drain_if_open entry in
        Cache.remove label None;
        Lwt.return_unit
    ;;

    let reset_label ?required label database =
      let%lwt () = drop label in
      register_database ?required database;
      Lwt.return_unit
    ;;

    let reset ?required database =
      reset_label ?required (Entity.Database.label database) database
    ;;

    let clear () = Cache.clear ()

    let key_description label role =
      match role with
      | None -> Entity.Label.show label
      | Some r ->
        Format.asprintf "%s (role: %s)" (Entity.Label.show label) (Entity.Role.show r)
    ;;

    let database_not_registered label role =
      Error (Error.Database_not_registered (key_description label role))
    ;;

    let connect ?role label =
      match Cache.find_opt label role with
      | None -> database_not_registered label role
      | Some entry ->
        let rec try_connect ({ Pool_entry.connection; _ } as e) =
          match connection with
          | Fail msg -> Error (Error.Connection_failed msg)
          | Close ->
            let e2 = Pool_entry.connect_base e in
            Cache.replace e2;
            try_connect e2
          | Open _ -> Ok ()
        in
        try_connect entry
    ;;

    let disconnect ?role label =
      match Cache.find_opt label role with
      | None -> Lwt.return_unit
      | Some entry ->
        let%lwt () = drain_if_open entry in
        Cache.replace (Pool_entry.mark_close entry);
        Lwt.return_unit
    ;;

    let disconnect_with_msg ?role label msg =
      match Cache.find_opt label role with
      | None -> Lwt.return_unit
      | Some entry ->
        let%lwt () = drain_if_open entry in
        Cache.replace (Pool_entry.mark_fail msg entry);
        Lwt.return_unit
    ;;

    let find_all ?(allowed_status = Entity.Status.all) ?(exclude = []) () =
      CCList.filter_map
        (fun { Pool_entry.database; role; _ } ->
           if Option.is_some role
           then None
           else (
             let lbl = Entity.Database.label database in
             let st = Entity.Database.status database in
             CCOption.return_if
               (CCList.mem ~eq:Entity.Status.equal st allowed_status
                && not (CCList.mem ~eq:Entity.Label.equal lbl exclude))
               database))
        (Cache.all ())
    ;;

    let fetch ?(retries = 2) ?role label =
      let raise_not_registered () =
        raise (Error.Exn (Error.Database_not_registered (key_description label role)))
      in
      let rec go () =
        match Cache.find_opt label role with
        | None -> raise_not_registered ()
        | Some ({ Pool_entry.connection; n_retries; _ } as entry) ->
          (match connection with
           | Open pool ->
             if n_retries > 0 then Cache.replace (Pool_entry.reset_retry entry);
             Lwt.return pool
           | Close ->
             Cache.replace (Pool_entry.connect_base entry);
             go ()
           | Fail _ when n_retries >= retries ->
             Pool_entry.raise_connection_failed
               (Format.asprintf
                  "All %d reconnect attempts exhausted for '%s'"
                  retries
                  (key_description label role))
           | Fail _ ->
             Cache.replace (Pool_entry.connect_base entry |> Pool_entry.increment_retry);
             go ())
      in
      go ()
    ;;

    let raise_caqti_error ?role label lwt_result =
      match%lwt lwt_result with
      | Ok v -> Lwt.return v
      | Error err ->
        let msg = Format.asprintf "%a" Caqti_error.pp err in
        let%lwt () = disconnect_with_msg ?role label msg in
        raise (Error.Exn (Error.Caqti_error msg))
    ;;

    let map_fetched ?retries ?role label f =
      let%lwt pool = fetch ?retries ?role label in
      f pool |> raise_caqti_error ?role label
    ;;
  end

  let query ?role label f = Caqti_lwt_unix.Pool.use f |> Pool.map_fetched ?role label

  let exec ?role label request input =
    query ?role label (fun conn ->
      let module C = (val conn : Caqti_lwt.CONNECTION) in
      C.exec request input)
  ;;

  let collect ?role label request input =
    query ?role label (fun conn ->
      let module C = (val conn : Caqti_lwt.CONNECTION) in
      C.collect_list request input)
  ;;

  let find ?role label request input =
    query ?role label (fun conn ->
      let module C = (val conn : Caqti_lwt.CONNECTION) in
      C.find request input)
  ;;

  let find_opt ?role label request input =
    query ?role label (fun conn ->
      let module C = (val conn : Caqti_lwt.CONNECTION) in
      C.find_opt request input)
  ;;

  let populate ?role label table column_names param_type rows =
    match rows with
    | [] -> Lwt.return_unit
    | _ ->
      let sql = Config.Dialect.insert_row ~table ~columns:column_names in
      let req = (param_type ->. Caqti_type.unit) ~oneshot:true sql in
      Lwt_list.iter_s (exec ?role label req) rows
  ;;

  let exec_each connection requests =
    let open Lwt_result.Infix in
    CCList.fold_left
      (fun acc f -> acc >>= fun () -> f connection)
      (Lwt_result.return ())
      requests
  ;;

  let rollback label connection exn =
    let (module C : Caqti_lwt.CONNECTION) = connection in
    let%lwt rollback_result = C.rollback () in
    (match rollback_result with
     | Ok () ->
       Log.debug (fun m -> m "Rolled back transaction on '%s'" (Entity.Label.show label))
     | Error err ->
       Log.warn (fun m ->
         m "Rollback failed on '%s': %a" (Entity.Label.show label) Caqti_error.pp err));
    Lwt.reraise exn
  ;;

  let transaction ?(setup = []) ?(cleanup = []) ?role label f =
    Caqti_lwt_unix.Pool.use (fun connection ->
      let (module C : Caqti_lwt.CONNECTION) = connection in
      let open Lwt_result.Infix in
      C.start ()
      >>= fun () ->
      Lwt.catch
        (fun () ->
           exec_each connection setup
           >>= fun () ->
           f connection
           >>= fun result ->
           exec_each connection cleanup
           >>= fun () -> C.commit () >>= fun () -> Lwt_result.return result)
        (rollback label connection))
    |> Pool.map_fetched ?role label
  ;;

  let transaction_iter ?role label queries =
    Caqti_lwt_unix.Pool.use (fun connection ->
      let (module C : Caqti_lwt.CONNECTION) = connection in
      let open Lwt_result.Infix in
      C.start ()
      >>= fun () ->
      Lwt.catch
        (fun () -> exec_each connection queries >>= fun () -> C.commit ())
        (rollback label connection))
    |> Pool.map_fetched ?role label
  ;;
end

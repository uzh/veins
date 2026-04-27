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
      ; connection : connection_state
      ; n_retries : int
      }

    let make ?(required = false) database =
      { database; required; connection = Close; n_retries = 0 }
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

    let connect_base ?(retries = 2) ({ required; _ } as entry) =
      let attempt () = entry |> database_url |> make_caqti_pool in
      let result = CCResult.retry retries attempt in
      match result with
      | Error [] ->
        raise (Error.Exn (Error.Connection_failed "Failed to connect: empty error list"))
      | Error (err :: _) when required ->
        raise
          (Error.Exn
             (Error.Connection_failed
                (Format.asprintf
                   "Required database '%s' unavailable: %a"
                   (Entity.Label.show (database_label entry))
                   Caqti_error.pp
                   err)))
      | Error (err :: _) ->
        let msg =
          Format.asprintf
            "Failed to connect to '%s': %a"
            (Entity.Label.show (database_label entry))
            Caqti_error.pp
            err
        in
        Log.warn (fun m -> m "%s" msg);
        { entry with connection = Fail msg }
      | Ok pool -> { entry with connection = Open pool }
    ;;
  end

  module Cache = struct
    module LabelHash = struct
      type t = Entity.Label.t

      let equal = Entity.Label.equal
      let hash = Entity.Label.hash
    end

    module Tbl = CCHashtbl.Make (LabelHash)

    let pools : Pool_entry.t Tbl.t = Tbl.create (max 1 Config.expected_databases)
    let clear () = Tbl.clear pools
    let find_opt label = Tbl.find_opt pools label
    let remove label = Tbl.remove pools label

    let replace (entry : Pool_entry.t) =
      Tbl.replace pools (Pool_entry.database_label entry) entry
    ;;

    let all () = Tbl.values_list pools
  end

  module Pool = struct
    let drain_if_open (entry : Pool_entry.t) =
      match entry.Pool_entry.connection with
      | Open pool ->
        let%lwt () = Caqti_lwt_unix.Pool.drain pool in
        Lwt.return_unit
      | Close | Fail _ -> Lwt.return_unit
    ;;

    let initialize ?(additional_pools = []) () =
      CCList.iter
        (fun db ->
           let label = Entity.Database.label db in
           if CCOption.is_none (Cache.find_opt label)
           then
             Pool_entry.make ~required:true db |> Pool_entry.connect_base |> Cache.replace)
        (Config.database :: additional_pools)
    ;;

    let add ?required database =
      let label = Entity.Database.label database in
      match Cache.find_opt label with
      | Some _ ->
        Log.warn (fun m ->
          m "Pool '%s' already registered; skipping add" (Entity.Label.show label))
      | None ->
        Pool_entry.make ?required database |> Pool_entry.connect_base |> Cache.replace
    ;;

    let drop label =
      match Cache.find_opt label with
      | None ->
        Log.info (fun m ->
          m "Pool '%s' not found; nothing to drop" (Entity.Label.show label));
        Lwt.return_unit
      | Some entry ->
        let%lwt () = drain_if_open entry in
        Cache.remove label;
        Lwt.return_unit
    ;;

    let reset ?required database =
      let%lwt () = drop (Entity.Database.label database) in
      Pool_entry.make ?required database |> Pool_entry.connect_base |> Cache.replace;
      Lwt.return_unit
    ;;

    let reset_label ?required label database =
      let%lwt () = drop label in
      Pool_entry.make ?required database |> Pool_entry.connect_base |> Cache.replace;
      Lwt.return_unit
    ;;

    let clear () = Cache.clear ()

    let connect label =
      match Cache.find_opt label with
      | None -> Error (Error.Database_not_registered (Entity.Label.show label))
      | Some entry ->
        let rec try_connect (e : Pool_entry.t) =
          match e.Pool_entry.connection with
          | Fail msg -> Error (Error.Connection_failed msg)
          | Close ->
            let e2 = Pool_entry.connect_base e in
            Cache.replace e2;
            try_connect e2
          | Open _ -> Ok ()
        in
        try_connect entry
    ;;

    let disconnect label =
      match Cache.find_opt label with
      | None -> Lwt.return_unit
      | Some entry ->
        let%lwt () = drain_if_open entry in
        Cache.replace (Pool_entry.mark_close entry);
        Lwt.return_unit
    ;;

    let disconnect_with_msg label msg =
      match Cache.find_opt label with
      | None -> Lwt.return_unit
      | Some entry ->
        let%lwt () = drain_if_open entry in
        Cache.replace (Pool_entry.mark_fail msg entry);
        Lwt.return_unit
    ;;

    let find_all ?(allowed_status = Entity.Status.all) ?(exclude = []) () =
      Cache.all ()
      |> CCList.filter (fun (e : Pool_entry.t) ->
        let lbl = Pool_entry.database_label e in
        let st = Entity.Database.status e.Pool_entry.database in
        CCList.mem ~eq:Entity.Status.equal st allowed_status
        && not (CCList.mem ~eq:Entity.Label.equal lbl exclude))
      |> CCList.map (fun (e : Pool_entry.t) -> e.Pool_entry.database)
    ;;

    let fetch ?(retries = 2) label =
      let rec go () =
        match Cache.find_opt label with
        | None ->
          raise (Error.Exn (Error.Database_not_registered (Entity.Label.show label)))
        | Some entry ->
          (match entry.Pool_entry.connection with
           | Open pool ->
             if entry.Pool_entry.n_retries > 0
             then Cache.replace (Pool_entry.reset_retry entry);
             Lwt.return pool
           | Close ->
             Cache.replace (Pool_entry.connect_base entry);
             go ()
           | Fail _ when entry.Pool_entry.n_retries >= retries ->
             raise
               (Error.Exn
                  (Error.Connection_failed
                     (Format.asprintf
                        "All %d reconnect attempts exhausted for '%s'"
                        retries
                        (Entity.Label.show label))))
           | Fail _ ->
             Cache.replace (Pool_entry.connect_base entry |> Pool_entry.increment_retry);
             go ())
      in
      go ()
    ;;

    let raise_caqti_error label lwt_result =
      match%lwt lwt_result with
      | Ok v -> Lwt.return v
      | Error err ->
        let msg = Format.asprintf "%a" Caqti_error.pp err in
        let%lwt () = disconnect_with_msg label msg in
        raise (Error.Exn (Error.Caqti_error msg))
    ;;

    let map_fetched ?retries label f =
      let%lwt pool = fetch ?retries label in
      f pool |> raise_caqti_error label
    ;;
  end

  let query label f = Caqti_lwt_unix.Pool.use f |> Pool.map_fetched label

  let exec label request input =
    query label (fun conn ->
      let module C = (val conn : Caqti_lwt.CONNECTION) in
      C.exec request input)
  ;;

  let collect label request input =
    query label (fun conn ->
      let module C = (val conn : Caqti_lwt.CONNECTION) in
      C.collect_list request input)
  ;;

  let find label request input =
    query label (fun conn ->
      let module C = (val conn : Caqti_lwt.CONNECTION) in
      C.find request input)
  ;;

  let find_opt label request input =
    query label (fun conn ->
      let module C = (val conn : Caqti_lwt.CONNECTION) in
      C.find_opt request input)
  ;;

  let populate label table column_names param_type rows =
    match rows with
    | [] -> Lwt.return_unit
    | _ ->
      let placeholders =
        CCList.replicate (CCList.length column_names) "?" |> CCString.concat ", "
      in
      let cols = CCString.concat ", " column_names in
      let sql =
        Format.asprintf "INSERT INTO %s (%s) VALUES (%s)" table cols placeholders
      in
      let req = (param_type ->. Caqti_type.unit) ~oneshot:true sql in
      Lwt_list.iter_s (exec label req) rows
  ;;

  let exec_each connection requests =
    Lwt_list.fold_left_s
      (fun acc f ->
         match acc with
         | Error e -> Lwt.return (Error e)
         | Ok () -> f connection)
      (Ok ())
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

  let transaction ?(setup = []) ?(cleanup = []) label f =
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
    |> Pool.map_fetched label
  ;;

  let transaction_iter label queries =
    Caqti_lwt_unix.Pool.use (fun connection ->
      let (module C : Caqti_lwt.CONNECTION) = connection in
      let open Lwt_result.Infix in
      C.start ()
      >>= fun () ->
      Lwt.catch
        (fun () -> exec_each connection queries >>= fun () -> C.commit ())
        (rollback label connection))
    |> Pool.map_fetched label
  ;;
end

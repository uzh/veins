module T = Caqti.Templater.T

let direct = Caqti.Templater.direct
let src = Logs.Src.create "veins.migration"

module Log = (val Logs.src_log src : Logs.LOG)

module Id = struct
  type t = string

  let create s = s

  (* Fixed namespace for {!derive}; never change it, derived ids are stored. *)
  let derive_namespace =
    Uuidm.of_string "b8f4c1d2-7a3e-4f6b-9c5d-2e1a0f8b7c63"
    |> CCOption.get_exn_or "Migration.Id: invalid namespace UUID"
  ;;

  let derive ~namespace ~index =
    if index < 0 then invalid_arg "Migration.Id.derive: negative index";
    Uuidm.v5 derive_namespace (Format.asprintf "%s/%d" namespace index) |> Uuidm.to_string
  ;;

  let value s = s
  let equal = CCString.equal
  let pp = Format.pp_print_string
  let show s = s
end

module Namespace = struct
  type t = string

  let create s = s
  let value s = s
  let equal = CCString.equal
  let pp = Format.pp_print_string
  let show s = s
end

module Sql = struct
  type t =
    { mariadb : string option
    ; postgresql : string option
    }

  let any sql = { mariadb = Some sql; postgresql = Some sql }

  let only (kind : Dialect.kind) sql =
    match kind with
    | Dialect.Mariadb -> { mariadb = Some sql; postgresql = None }
    | Dialect.Postgresql -> { mariadb = None; postgresql = Some sql }
  ;;

  let v ?mariadb ?postgresql () =
    match mariadb, postgresql with
    | None, None -> invalid_arg "Migration.Sql.v: no SQL for any dialect"
    | _ -> { mariadb; postgresql }
  ;;

  let for_kind { mariadb; postgresql } : Dialect.kind -> string option = function
    | Dialect.Mariadb -> mariadb
    | Dialect.Postgresql -> postgresql
  ;;

  let kinds t =
    CCList.filter
      (fun kind -> CCOption.is_some (for_kind t kind))
      Dialect.[ Mariadb; Postgresql ]
  ;;

  let is_placeholder sql = CCString.prefix ~pre:"TODO:" (CCString.trim sql)

  let written t kind =
    match for_kind t kind with
    | Some sql -> not (is_placeholder sql)
    | None -> false
  ;;
end

module Step = struct
  type t =
    { id : Id.t option
    ; label : string
    ; up : Sql.t
    ; down : Sql.t option
    ; check_fk : bool
    }

  let create ?id ~label ?(check_fk = true) ?down up = { id; label; up; down; check_fk }
  let id { id; _ } = id
end

type t =
  { namespace : Namespace.t
  ; written_at : Ptime.t
  ; steps : Step.t list
  }

let ptime_of_string s =
  match Ptime.of_rfc3339 s with
  | Ok (t, _, _) -> t
  | Error _ ->
    invalid_arg
      (Format.asprintf "Migration.ptime_of_string: invalid RFC 3339 string: %S" s)
;;

let create namespace ~written_at = { namespace; written_at; steps = [] }
let add_step s m = { m with steps = m.steps @ [ s ] }

(* A step with its id: the given one, or the one derived from its position. *)
module Resolved = struct
  type t =
    { id : Id.t
    ; label : string
    ; up : Sql.t
    ; down : Sql.t option
    ; check_fk : bool
    }
end

let resolve { namespace; steps; _ } =
  CCList.mapi
    (fun index { Step.id; label; up; down; check_fk } ->
       let id =
         match id with
         | Some id -> id
         | None -> Id.derive ~namespace:(Namespace.value namespace) ~index
       in
       { Resolved.id; label; up; down; check_fk })
    steps
;;

let step_ids m = CCList.map (fun { Resolved.id; _ } -> id) (resolve m)

type database_target =
  | Database of Entity.Label.t
  | Databases of Entity.Label.t list
  | All
  | AllExcept of Entity.Label.t list

let target_applies_to (target : database_target) (label : Entity.Label.t) =
  match target with
  | Database lbl -> Entity.Label.equal lbl label
  | Databases lbls -> CCList.mem ~eq:Entity.Label.equal label lbls
  | All -> true
  | AllExcept lbls -> not (CCList.mem ~eq:Entity.Label.equal label lbls)
;;

let registry : (database_target * t) list ref = ref []

let register ?(for_databases = All) migration =
  registry := (for_databases, migration) :: !registry
;;

(* The name goes into SQL as it is. *)
let table_name =
  lazy
    (match Sys.getenv_opt "VEINS_MIGRATION_TABLE" with
     | Some t when Dialect.is_identifier t -> t
     | Some t when not (CCString.is_empty t) ->
       invalid_arg
         (Format.asprintf "VEINS_MIGRATION_TABLE: %S is not a plain table name" t)
     | _ -> "veins_migration_state")
;;

let state_table () = Lazy.force table_name

let lock_timeout =
  lazy
    (match
       CCOption.flat_map
         float_of_string_opt
         (Sys.getenv_opt "VEINS_MIGRATION_LOCK_TIMEOUT")
     with
     | Some seconds when seconds >= 0. -> seconds
     | _ -> 600.)
;;

(* Current wall-clock time as a Ptime.t, safe for Caqti.Template.Row_type.ptime. *)
let now () =
  CCOption.get_or ~default:Ptime.epoch (Ptime.of_float_s (Unix.gettimeofday ()))
;;

type drift =
  | Pending of
      { namespace : Namespace.t
      ; pending_steps : int
      ; total_steps : int
      }
  | Orphaned of
      { namespace : Namespace.t
      ; step_ids : Id.t list
      }
  | Unsupported of
      { namespace : Namespace.t
      ; dialect : Dialect.kind
      ; steps : string list
      }

module type RunnerSig = sig
  val run_all
    :  ?role:_ Entity.Role.t
    -> ?migrations:t list
    -> Entity.Label.t
    -> unit
    -> (unit, Error.t) Lwt_result.t

  val up : ?role:_ Entity.Role.t -> Entity.Label.t -> t -> (unit, Error.t) Lwt_result.t

  val mark_applied
    :  ?role:_ Entity.Role.t
    -> Entity.Label.t
    -> t
    -> steps:int
    -> unit Lwt.t

  val down : ?role:_ Entity.Role.t -> Entity.Label.t -> t -> (unit, Error.t) Lwt_result.t

  val verify
    :  ?role:_ Entity.Role.t
    -> ?migrations:t list
    -> Entity.Label.t
    -> unit
    -> (unit, Error.t) Lwt_result.t

  val check
    :  ?role:_ Entity.Role.t
    -> ?migrations:t list
    -> Entity.Label.t
    -> unit
    -> drift list Lwt.t

  val status
    :  ?role:_ Entity.Role.t
    -> ?migrations:t list
    -> Entity.Label.t
    -> unit
    -> (Namespace.t * int * int) list Lwt.t

  val pending
    :  ?role:_ Entity.Role.t
    -> ?migrations:t list
    -> Entity.Label.t
    -> unit
    -> (Namespace.t * int) list Lwt.t
end

module Make (Db : Pools_sig.Sig) : RunnerSig = struct
  (* Migrations run as the role the caller names (the owner by default); the
     database enforces its rights, so their statements declare no needs. *)
  let unchecked request = Request.create ~needs:Entity.Need.none request
  let table = state_table

  (* Return migrations targeting [db_label], sorted by written_at ascending. *)
  let registered_for db_label =
    CCList.filter_map
      (fun (target, mig) -> CCOption.return_if (target_applies_to target db_label) mig)
      !registry
    |> CCList.sort (fun a b -> Ptime.compare a.written_at b.written_at)
  ;;

  let migrations_for ?migrations db_label =
    match migrations with
    | Some migrations -> migrations
    | None -> registered_for db_label
  ;;

  let applied_id_set ids =
    let tbl = Hashtbl.create (max 1 (CCList.length ids)) in
    CCList.iter (fun id -> Hashtbl.replace tbl id ()) ids;
    tbl
  ;;

  let is_applied = Hashtbl.mem

  let kind_of ctx =
    let (module C : Caqti_lwt.CONNECTION) =
      Ctx.Internal.connection ctx
      |> CCOption.get_exn_or "migration context without connection"
    in
    Dialect.kind C.dialect
  ;;

  let kind_name : Dialect.kind -> string = function
    | Dialect.Mariadb -> "MariaDB"
    | Dialect.Postgresql -> "PostgreSQL"
  ;;

  (* The labels of the pending steps of every migration that has no SQL for
     [kind], or only a placeholder. *)
  let unsupported kind applied migrations =
    CCList.filter_map
      (fun mig ->
         let labels =
           CCList.filter_map
             (fun { Resolved.id; label; up; _ } ->
                if is_applied applied id || Sql.written up kind then None else Some label)
             (resolve mig)
         in
         if CCList.is_empty labels then None else Some (mig.namespace, labels))
      migrations
  ;;

  let unsupported_error ?(revert = false) kind unsupported =
    let describe (namespace, labels) =
      Format.asprintf "'%s' (%s)" (Namespace.show namespace) (CCString.concat ", " labels)
    in
    let msg =
      Format.asprintf
        "No %s SQL (or a TODO: placeholder) for %s of %s; nothing was %s"
        (kind_name kind)
        (if revert then "reverting the applied steps" else "the pending steps")
        (CCString.concat ", " (CCList.map describe unsupported))
        (if revert then "reverted" else "applied")
    in
    Log.err (fun m -> m "%s" msg);
    Error.Migration_failed msg
  ;;

  (* The state table's SQL follows the dialect of the connection it runs on. *)
  let state_request request_type sql =
    Dialect.request Caqti.Template.Request.Direct request_type (fun kind ->
      sql kind ~table:(table ()))
    |> unchecked
  ;;

  let setup ctx =
    Db.exec ctx (state_request T.(unit -->. unit) Dialect.create_migration_table) ()
  ;;

  (* Reading the state must work for a role that may not create tables: a
     missing state table means nothing was applied. *)
  let state_exists ctx =
    let request =
      Dialect.request
        Caqti.Template.Request.Direct
        T.(string -->! int)
        Dialect.table_exists
      |> unchecked
    in
    let%lwt tables = Db.find ctx request (table ()) in
    Lwt.return (tables > 0)
  ;;

  let get_applied_rows ctx =
    if%lwt state_exists ctx
    then (
      let%lwt rows =
        Db.collect
          ctx
          (state_request T.(unit -->* t2 string string) Dialect.select_applied_rows)
          ()
      in
      Lwt.return (CCList.map (fun (id, ns) -> Id.create id, Namespace.create ns) rows))
    else Lwt.return []
  ;;

  let get_applied_ids ctx =
    let%lwt ids =
      Db.collect ctx (state_request T.(unit -->* string) Dialect.select_applied_ids) ()
    in
    Lwt.return (CCList.map Id.create ids)
  ;;

  let insert_applied_step ctx namespace { Resolved.id; label; _ } =
    let n = now () in
    let req =
      state_request
        T.(t2 (t3 string string string) (t2 ptime ptime) -->. unit)
        Dialect.insert_applied_step
    in
    Db.exec ctx req ((Id.value id, Namespace.value namespace, label), (n, n))
  ;;

  let delete_applied_step ctx (step_id : Id.t) =
    Db.exec
      ctx
      (state_request T.(string -->. unit) Dialect.delete_applied_step)
      (Id.value step_id)
  ;;

  (* [SET FOREIGN_KEY_CHECKS] is session state: runner contexts hold one
     connection, so both toggles and the step run on it. The step's own
     statements go through [ctx], whose mutex [Db.query] would hold. *)
  let with_fk_disabled ctx f =
    let connection =
      Ctx.Internal.connection ctx
      |> CCOption.get_exn_or "migration context without connection"
    in
    let%lwt result =
      Connection.without_fk_checks connection (fun () -> Lwt_result.ok (f ()))
    in
    (* raises veins' usual exception, with label and role, on [Error] *)
    Db.query ~needs:Entity.Need.none ctx (fun (_ : Caqti_lwt.connection) ->
      Lwt.return result)
  ;;

  (* The step and its state row commit together where the dialect has
     transactional DDL (PostgreSQL); MariaDB commits DDL implicitly. *)
  let run_statement ctx ~check_fk sql record =
    let run () =
      Db.with_transaction ctx (fun ctx ->
        let%lwt () = Db.exec ctx (direct T.(unit -->. unit) sql |> unchecked) () in
        record ctx)
    in
    if check_fk then run () else with_fk_disabled ctx run
  ;;

  (* [verify] ran before: a step without SQL for [kind] is a bug here. *)
  let sql_for kind label sql =
    match Sql.for_kind sql kind with
    | Some sql -> sql
    | None ->
      raise
        (Error.Exn
           (Error.Migration_failed
              (Format.asprintf "Step '%s' has no %s SQL" label (kind_name kind))))
  ;;

  let run_step_up ctx kind namespace ({ Resolved.id; label; up; check_fk; _ } as s) =
    Log.debug (fun m -> m "Applying step '%s' (%s)" label (Id.show id));
    run_statement ctx ~check_fk (sql_for kind label up) (fun ctx ->
      insert_applied_step ctx namespace s)
  ;;

  let run_step_down ctx kind { Resolved.id; label; down; check_fk; _ } =
    match down with
    | None ->
      Log.warn (fun m ->
        m "Step '%s' (%s) has no down migration; skipping" label (Id.show id));
      Lwt.return_unit
    | Some sql ->
      Log.debug (fun m -> m "Reverting step '%s' (%s)" label (Id.show id));
      run_statement ctx ~check_fk (sql_for kind label sql) (fun ctx ->
        delete_applied_step ctx id)
  ;;

  let failed fmt mig exn =
    let msg =
      Format.asprintf fmt (Namespace.show mig.namespace) (Printexc.to_string exn)
    in
    Log.err (fun m -> m "%s" msg);
    Lwt_result.fail (Error.Migration_failed msg)
  ;;

  (* Before anything runs: every pending step of [migrations] has SQL for the
     connection's dialect. *)
  let verified ctx migrations f =
    let kind = kind_of ctx in
    let%lwt applied = get_applied_rows ctx in
    let applied = applied_id_set (CCList.map fst applied) in
    match unsupported kind applied migrations with
    | [] -> f kind
    | unsupported -> Lwt_result.fail (unsupported_error kind unsupported)
  ;;

  let apply_up ctx kind mig =
    let%lwt applied_ids = get_applied_ids ctx in
    let applied = applied_id_set applied_ids in
    let pending_steps =
      CCList.filter (fun { Resolved.id; _ } -> not (is_applied applied id)) (resolve mig)
    in
    match CCList.length pending_steps with
    | 0 ->
      Log.info (fun m ->
        m "No pending steps for migration '%s'" (Namespace.show mig.namespace));
      Lwt_result.return ()
    | n ->
      Log.info (fun m ->
        m "Applying %d step(s) for migration '%s'" n (Namespace.show mig.namespace));
      Lwt.catch
        (fun () ->
           let%lwt () =
             Lwt_list.iter_s (run_step_up ctx kind mig.namespace) pending_steps
           in
           Lwt_result.return ())
        (failed "Migration '%s' failed: %s" mig)
  ;;

  (* The pools' statement timeout is for the application's statements, not
     for migrations: lift it on the held connection, and put it back before
     the connection returns to the pool. *)
  let without_statement_timeout ctx f =
    let set timeout =
      Db.query
        ~needs:Entity.Need.none
        ctx
        (fun (module Connection : Caqti_lwt.CONNECTION) ->
           Connection.set_statement_timeout timeout)
    in
    match Db.options.Pool_options.statement_timeout with
    | None -> f ()
    | Some (_ : float) as timeout ->
      let%lwt () = set None in
      Lwt.finalize f (fun () -> set timeout)
  ;;

  let lock_name () = "veins_migration:" ^ table ()

  let lock_request sql =
    Dialect.request Caqti.Template.Request.Direct T.(string -->! int) sql |> unchecked
  ;;

  (* One runner at a time per database, also across processes: instances
     starting together would otherwise apply the same steps side by side. The
     lock belongs to the session, i.e. to the connection [ctx] holds. *)
  let with_lock ctx f =
    let name = lock_name () in
    let timeout = Lazy.force lock_timeout in
    let try_lock () =
      let%lwt locked = Db.find ctx (lock_request Dialect.try_lock) name in
      Lwt.return (locked = 1)
    in
    let rec acquire waited =
      if%lwt try_lock ()
      then Lwt.return_unit
      else if waited >= timeout
      then
        raise
          (Error.Exn
             (Error.Migration_failed
                (Format.asprintf
                   "Another process has been migrating this database for more than %gs"
                   timeout)))
      else (
        if waited = 0.
        then Log.info (fun m -> m "Waiting for another process migrating this database");
        let pause = CCFloat.min 0.5 (timeout -. waited) in
        let%lwt () = Lwt_unix.sleep pause in
        acquire (waited +. pause))
    in
    let%lwt () = acquire 0. in
    Lwt.finalize f (fun () ->
      Lwt.catch
        (fun () ->
           let%lwt (_ : int) = Db.find ctx (lock_request Dialect.unlock) name in
           Lwt.return_unit)
        (fun exn ->
           (* a lost connection released it already *)
           Log.debug (fun m ->
             m "Releasing the migration lock failed: %s" (Printexc.to_string exn));
           Lwt.return_unit))
  ;;

  let with_read_ctx ?(role = Entity.Role.owner) db_label f =
    Db.connection_ctx ~role db_label f
  ;;

  let with_ctx ?(role = Entity.Role.owner) db_label f =
    Db.connection_ctx ~role db_label (fun ctx ->
      without_statement_timeout ctx (fun () ->
        with_lock ctx (fun () ->
          let%lwt () = setup ctx in
          f ctx)))
  ;;

  let lock_error f =
    Lwt.catch f (function[@warning "-4"]
      | Error.Exn (Error.Migration_failed _ as error) -> Lwt_result.fail error
      | exn -> Lwt.reraise exn)
  ;;

  let up ?role db_label mig =
    lock_error (fun () ->
      with_ctx ?role db_label (fun ctx ->
        verified ctx [ mig ] (fun kind -> apply_up ctx kind mig)))
  ;;

  let mark_applied ?role db_label mig ~steps =
    with_ctx ?role db_label
    @@ fun ctx ->
    let%lwt applied_ids = get_applied_ids ctx in
    let applied = applied_id_set applied_ids in
    let to_mark =
      CCList.take steps (resolve mig)
      |> CCList.filter (fun { Resolved.id; _ } -> not (is_applied applied id))
    in
    let%lwt () =
      Db.with_transaction ctx (fun ctx ->
        Lwt_list.iter_s (insert_applied_step ctx mig.namespace) to_mark)
    in
    if not (CCList.is_empty to_mark)
    then
      Log.info (fun m ->
        m
          "Marked %d step(s) of migration '%s' as applied"
          (CCList.length to_mark)
          (Namespace.show mig.namespace));
    Lwt.return_unit
  ;;

  let down ?role db_label mig =
    lock_error
    @@ fun () ->
    with_ctx ?role db_label
    @@ fun ctx ->
    let%lwt applied_ids = get_applied_ids ctx in
    let applied_set = applied_id_set applied_ids in
    let applied =
      CCList.filter (fun { Resolved.id; _ } -> is_applied applied_set id) (resolve mig)
    in
    let kind = kind_of ctx in
    let missing_down =
      CCList.filter_map
        (fun { Resolved.label; down; _ } ->
           match down with
           | Some down when not (Sql.written down kind) -> Some label
           | Some _ | None -> None)
        applied
    in
    match CCList.length applied with
    | (_ : int) when not (CCList.is_empty missing_down) ->
      Lwt_result.fail
        (unsupported_error ~revert:true kind [ mig.namespace, missing_down ])
    | 0 ->
      Log.info (fun m ->
        m "No applied steps to revert for migration '%s'" (Namespace.show mig.namespace));
      Lwt_result.return ()
    | n ->
      Log.info (fun m ->
        m "Reverting %d step(s) for migration '%s'" n (Namespace.show mig.namespace));
      Lwt.catch
        (fun () ->
           let%lwt () = Lwt_list.iter_s (run_step_down ctx kind) (CCList.rev applied) in
           Lwt_result.return ())
        (failed "Migration '%s' revert failed: %s" mig)
  ;;

  let run_all ?role ?migrations db_label () =
    lock_error
    @@ fun () ->
    with_ctx ?role db_label
    @@ fun ctx ->
    let migrations = migrations_for ?migrations db_label in
    verified ctx migrations
    @@ fun kind ->
    let rec run = function
      | [] -> Lwt_result.return ()
      | mig :: rest ->
        (match%lwt apply_up ctx kind mig with
         | Error e -> Lwt_result.fail e
         | Ok () -> run rest)
    in
    run migrations
  ;;

  let verify ?role ?migrations db_label () =
    with_read_ctx ?role db_label
    @@ fun ctx ->
    verified ctx (migrations_for ?migrations db_label) (fun (_ : Dialect.kind) ->
      Lwt_result.return ())
  ;;

  let status ?role ?migrations db_label () =
    with_read_ctx ?role db_label
    @@ fun ctx ->
    let%lwt applied_rows = get_applied_rows ctx in
    let applied = applied_id_set (CCList.map fst applied_rows) in
    Lwt.return
    @@ CCList.map
         (fun mig ->
            let total = CCList.length (resolve mig) in
            let n_applied =
              CCList.count (fun { Resolved.id; _ } -> is_applied applied id) (resolve mig)
            in
            mig.namespace, n_applied, total)
         (migrations_for ?migrations db_label)
  ;;

  let pending ?role ?migrations db_label () =
    let%lwt statuses = status ?role ?migrations db_label () in
    Lwt.return
    @@ CCList.filter_map
         (fun (ns, applied, total) ->
            let n = total - applied in
            CCOption.return_if (n > 0) (ns, n))
         statuses
  ;;

  let check ?role ?migrations db_label () =
    with_read_ctx ?role db_label
    @@ fun ctx ->
    let%lwt applied_rows = get_applied_rows ctx in
    let applied = applied_id_set (CCList.map fst applied_rows) in
    let migs = migrations_for ?migrations db_label in
    (* All step IDs currently in the registry for this label *)
    let registered_set = CCList.flat_map step_ids migs |> applied_id_set in
    (* Pending: steps in registry not yet applied *)
    let pending_drifts =
      CCList.filter_map
        (fun mig ->
           let total = CCList.length (resolve mig) in
           let applied_count =
             CCList.count (fun { Resolved.id; _ } -> is_applied applied id) (resolve mig)
           in
           let n = total - applied_count in
           if n > 0
           then (
             Log.warn (fun m ->
               m
                 "[check] Migration '%s' on '%s': %d/%d step(s) pending"
                 (Namespace.show mig.namespace)
                 (Entity.Label.show db_label)
                 n
                 total);
             Some
               (Pending
                  { namespace = mig.namespace; pending_steps = n; total_steps = total }))
           else None)
        migs
    in
    (* Orphaned: applied IDs not in any registered migration *)
    let orphaned_rows =
      CCList.filter (fun (id, _ns) -> not (is_applied registered_set id)) applied_rows
    in
    (* Group orphaned IDs by their stored namespace *)
    let group_by_ns rows =
      let tbl = Hashtbl.create 4 in
      CCList.iter
        (fun (id, ns) ->
           let prev = CCOption.get_or ~default:[] (Hashtbl.find_opt tbl ns) in
           Hashtbl.replace tbl ns (id :: prev))
        rows;
      Hashtbl.fold (fun ns ids acc -> (ns, ids) :: acc) tbl []
    in
    let orphan_drifts =
      CCList.map
        (fun (ns, ids) ->
           Log.warn (fun m ->
             m
               "[check] Database '%s' has %d orphaned step(s) in namespace '%s' not \
                found in registry: [%s]"
               (Entity.Label.show db_label)
               (CCList.length ids)
               (Namespace.show ns)
               (CCString.concat ", " (CCList.map Id.show ids)));
           Orphaned { namespace = ns; step_ids = ids })
        (group_by_ns orphaned_rows)
    in
    let kind = kind_of ctx in
    let unsupported_drifts =
      CCList.map
        (fun (namespace, steps) ->
           Log.warn (fun m ->
             m
               "[check] Migration '%s' on '%s' has no %s SQL for %d pending step(s)"
               (Namespace.show namespace)
               (Entity.Label.show db_label)
               (kind_name kind)
               (CCList.length steps));
           Unsupported { namespace; dialect = kind; steps })
        (unsupported kind applied migs)
    in
    Lwt.return (pending_drifts @ orphan_drifts @ unsupported_drifts)
  ;;
end

module Counter_state = struct
  type row =
    { namespace : string
    ; version : int
    ; dirty : bool
    }

  type state =
    { exists : bool
    ; rows : row list
    }

  let default_table = "core_migration_state"

  let table_name = function
    | None -> default_table
    | Some table when Dialect.is_identifier table -> table
    | Some table ->
      invalid_arg
        (Format.asprintf "Migration.Counter_state: %S is not a plain table name" table)
  ;;

  let create_table (kind : Dialect.kind) ~table =
    match kind with
    | Dialect.Mariadb ->
      Format.asprintf
        {sql|CREATE TABLE IF NOT EXISTS %s (
               namespace VARCHAR(128) NOT NULL,
               version INTEGER,
               dirty BOOL NOT NULL,
               PRIMARY KEY (namespace)
             ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci|sql}
        table
    | Dialect.Postgresql ->
      Format.asprintf
        {sql|CREATE TABLE IF NOT EXISTS %s (
               namespace VARCHAR(128) NOT NULL PRIMARY KEY,
               version INTEGER,
               dirty BOOLEAN NOT NULL
             )|sql}
        table
  ;;

  let select_rows (_ : Dialect.kind) ~table =
    Format.asprintf "SELECT namespace, version, dirty FROM %s" table
  ;;

  let upsert (kind : Dialect.kind) ~table =
    match kind with
    | Dialect.Mariadb ->
      Format.asprintf
        "INSERT INTO %s (namespace, version, dirty) VALUES (?, ?, ?) ON DUPLICATE KEY \
         UPDATE version = VALUES(version), dirty = VALUES(dirty)"
        table
    | Dialect.Postgresql ->
      Format.asprintf
        "INSERT INTO %s (namespace, version, dirty) VALUES (?, ?, ?) ON CONFLICT \
         (namespace) DO UPDATE SET version = EXCLUDED.version, dirty = EXCLUDED.dirty"
        table
  ;;

  module Make (Db : Pools_sig.Sig) = struct
    module Runner = Make (Db)

    let request request_type sql ~table =
      Dialect.request Caqti.Template.Request.Direct request_type (fun kind ->
        sql kind ~table)
      |> Request.create ~needs:Entity.Need.none
    ;;

    let read ?(role = Entity.Role.owner) ?table db_label =
      let table = table_name table in
      Db.connection_ctx ~role db_label
      @@ fun ctx ->
      let%lwt count =
        Db.find
          ctx
          (Dialect.request
             Caqti.Template.Request.Direct
             T.(string -->! int)
             Dialect.table_exists
           |> Request.create ~needs:Entity.Need.none)
          table
      in
      if count = 0
      then Lwt.return { exists = false; rows = [] }
      else (
        let%lwt rows =
          Db.collect
            ctx
            (request T.(unit -->* t3 string (option int) bool) select_rows ~table)
            ()
        in
        Lwt.return
          { exists = true
          ; rows =
              CCList.map
                (fun (namespace, version, dirty) ->
                   { namespace; version = CCOption.value ~default:0 version; dirty })
                rows
          })
    ;;

    let find { rows; _ } namespace =
      CCList.find_opt (fun (row : row) -> CCString.equal row.namespace namespace) rows
    ;;

    let import ?role ?table db_label migrations =
      let%lwt state = read ?role ?table db_label in
      match CCList.filter (fun ({ dirty; _ } : row) -> dirty) state.rows with
      | _ :: _ as dirty ->
        let namespaces = CCList.map (fun ({ namespace; _ } : row) -> namespace) dirty in
        CCList.iter
          (fun namespace ->
             Log.err (fun m ->
               m
                 "Migration '%s' on '%s' is marked dirty in %s: fix the database, then \
                  set dirty to false"
                 namespace
                 (Entity.Label.show db_label)
                 (table_name table)))
          namespaces;
        Lwt.return_error (`Dirty namespaces)
      | [] ->
        let%lwt () =
          Lwt_list.iter_s
            (fun (mig : t) ->
               match find state (Namespace.value mig.namespace) with
               | Some ({ version; _ } : row) when version > 0 ->
                 Runner.mark_applied ?role db_label mig ~steps:version
               | Some _ | None -> Lwt.return_unit)
            migrations
        in
        Lwt.return_ok state
    ;;

    let record
          ?(role = Entity.Role.owner)
          ?table
          db_label
          state
          namespace
          ~applied
          ~failed
      =
      let table = table_name table in
      let namespace = Namespace.value namespace in
      let unchanged =
        CCOption.map_or
          ~default:false
          (fun ({ version; dirty; _ } : row) -> version = applied && dirty = failed)
          (find state namespace)
      in
      if unchanged
      then Lwt.return_unit
      else
        Db.connection_ctx ~role db_label
        @@ fun ctx ->
        let%lwt () =
          if state.exists
          then Lwt.return_unit
          else Db.exec ctx (request T.(unit -->. unit) create_table ~table) ()
        in
        Db.exec
          ctx
          (request T.(t3 string int bool -->. unit) upsert ~table)
          (namespace, applied, failed)
    ;;
  end
end

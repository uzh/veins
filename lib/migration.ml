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
  let compare = CCString.compare
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
    ; check_fk : bool
    }

  let create ?id ~label ?(check_fk = true) up = { id; label; up; check_fk }
  let id { id; _ } = id
end

type t =
  { namespace : Namespace.t
  ; written_at : Ptime.t
  ; steps : Step.t list
  }

type migration = t

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
    ; check_fk : bool
    }
end

let resolve_steps { namespace; steps; _ } =
  CCList.mapi
    (fun index { Step.id; label; up; check_fk } ->
       let id =
         match id with
         | Some id -> id
         | None -> Id.derive ~namespace:(Namespace.value namespace) ~index
       in
       { Resolved.id; label; up; check_fk })
    steps
;;

let step_ids m = CCList.map (fun { Resolved.id; _ } -> id) (resolve_steps m)

(* {1 Order} *)

let compare_written (a : t) (b : t) =
  match Ptime.compare a.written_at b.written_at with
  | 0 -> Namespace.compare a.namespace b.namespace
  | c -> c
;;

let order migrations = CCList.stable_sort compare_written migrations

(* {1 Registration} *)

(* The default set, oldest first. *)
let registry : t list ref = ref []

let register migration =
  if
    CCList.exists
      (fun (m : t) -> Namespace.equal m.namespace migration.namespace)
      !registry
  then
    invalid_arg
      (Format.asprintf
         "Migration.register: '%s' is registered twice"
         (Namespace.show migration.namespace));
  registry := !registry @ [ migration ]
;;

let registered () = !registry

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

let kind_name : Dialect.kind -> string = function
  | Dialect.Mariadb -> "MariaDB"
  | Dialect.Postgresql -> "PostgreSQL"
;;

(* {1 State} *)

module Row_status = struct
  type t =
    | Applied
    | Failed

  let to_string = function
    | Applied -> "applied"
    | Failed -> "failed"
  ;;

  let of_string = function
    | "applied" -> Ok Applied
    | "failed" -> Ok Failed
    | other -> Error (Format.asprintf "unknown migration step status %S" other)
  ;;

  let equal a b =
    match a, b with
    | Applied, Applied | Failed, Failed -> true
    | Applied, Failed | Failed, Applied -> false
  ;;

  let pp f t = Format.pp_print_string f (to_string t)

  let caqti =
    Caqti.Template.Row_type.custom
      ~encode:(fun t -> Ok (to_string t))
      ~decode:of_string
      Caqti.Template.Row_type.string
  ;;
end

type row =
  { id : int option
  ; uuid : Id.t
  ; namespace : Namespace.t
  ; label : string
  ; status : Row_status.t
  ; last_error : string option
  ; run_at : Ptime.t option
  }

module Row = struct
  type t = row =
    { id : int option
    ; uuid : Id.t
    ; namespace : Namespace.t
    ; label : string
    ; status : Row_status.t
    ; last_error : string option
    ; run_at : Ptime.t option
    }
end

let is_applied_row row = Row_status.equal row.status Row_status.Applied
let is_failed_row row = Row_status.equal row.status Row_status.Failed

module Repair = struct
  let mark_applied kind uuid =
    Dialect.repair_mark_applied kind ~table:(state_table ()) ~uuid:(Id.value uuid)
  ;;

  let delete kind uuid =
    Dialect.repair_delete kind ~table:(state_table ()) ~uuid:(Id.value uuid)
  ;;
end

let pp_time f time = Ptime.pp_rfc3339 ~frac_s:0 () f time

let pp_failed_row ?dialect f row =
  Format.fprintf
    f
    "step %a of '%a' (%s)%a%a"
    Id.pp
    row.uuid
    Namespace.pp
    row.namespace
    row.label
    (Format.pp_print_option (fun f -> Format.fprintf f ", row %d"))
    row.id
    (Format.pp_print_option (fun f -> Format.fprintf f ", failed %a" pp_time))
    row.run_at;
  CCOption.iter (Format.fprintf f ":@\n      %s") row.last_error;
  CCOption.iter
    (fun kind ->
       Format.fprintf
         f
         "@\n\
         \    completed by hand, mark it applied: %s;@\n\
         \    undone by hand, run it again: %s;"
         (Repair.mark_applied kind row.uuid)
         (Repair.delete kind row.uuid))
    dialect
;;

(* Namespaces and step ids that occur more than once in [migrations]. *)
let duplicates (migrations : t list) =
  let repeated values =
    CCList.sort CCString.compare values
    |> CCList.group_succ ~eq:CCString.equal
    |> CCList.filter_map (function
      | value :: _ :: _ -> Some value
      | [ _ ] | [] -> None)
  in
  ( repeated (CCList.map (fun (mig : t) -> Namespace.value mig.namespace) migrations)
  , repeated
      (CCList.flat_map (fun (mig : t) -> CCList.map Id.value (step_ids mig)) migrations) )
;;

let duplicates_message = function
  | [], [] -> None
  | namespaces, ids ->
    let part what = function
      | [] -> None
      | values -> Some (Format.asprintf "%s %s" what (CCString.concat ", " values))
    in
    Some
      (Format.asprintf
         "Migrations registered twice (%s); nothing was applied"
         (CCString.concat
            "; "
            (CCList.filter_map
               CCFun.id
               [ part "namespaces" namespaces; part "step ids" ids ])))
;;

module Id_set = CCSet.Make (CCString)

let id_set = Id_set.of_list

let applied_set rows =
  id_set
    (CCList.filter_map
       (fun (r : row) -> CCOption.return_if (is_applied_row r) r.uuid)
       rows)
;;

let is_in set id = Id_set.mem id set

(* The labels of the pending steps of every migration that has no SQL for
   [kind], or only a placeholder. Steps with a row (applied or failed) are
   not pending. *)
let unsupported kind with_row (migrations : t list) =
  CCList.filter_map
    (fun (mig : t) ->
       let labels =
         CCList.filter_map
           (fun { Resolved.id; label; up; _ } ->
              if is_in with_row id || Sql.written up kind then None else Some label)
           (resolve_steps mig)
       in
       if CCList.is_empty labels then None else Some (mig.namespace, labels))
    migrations
;;

let unsupported_message kind unsupported =
  let describe (namespace, labels) =
    Format.asprintf "'%s' (%s)" (Namespace.show namespace) (CCString.concat ", " labels)
  in
  Format.asprintf
    "No %s SQL (or a TODO: placeholder) for the pending steps of %s; nothing was applied"
    (kind_name kind)
    (CCString.concat ", " (CCList.map describe unsupported))
;;

let failed_message ?dialect failed =
  Format.asprintf
    "@[<v>A step failed and blocks the migrations until it is repaired by hand:@,%a@]"
    (Format.pp_print_list (fun f row ->
       Format.fprintf f "  %a" (pp_failed_row ?dialect) row))
    failed
;;

module Make_internal (Db : Pools_sig.Sig) = struct
  (* Migrations run as the role the caller names (the owner by default); the
     database enforces its rights, so their statements declare no needs. *)
  let unchecked request = Request.create ~needs:Entity.Need.none request
  let table = state_table

  let kind_of ctx =
    let (module C : Caqti_lwt.CONNECTION) =
      Ctx.Internal.connection ctx
      |> CCOption.get_exn_or "migration context without connection"
    in
    Dialect.kind C.dialect
  ;;

  (* The state table's SQL follows the dialect of the connection it runs on. *)
  let state_request request_type sql =
    Dialect.request Caqti.Template.Request.Direct request_type (fun kind ->
      sql kind ~table:(table ()))
    |> unchecked
  ;;

  let count_request sql =
    Dialect.request Caqti.Template.Request.Direct T.(string -->! int) sql |> unchecked
  ;;

  let column_request =
    Dialect.request
      Caqti.Template.Request.Direct
      T.(t2 string string -->! int)
      Dialect.column_exists
    |> unchecked
  ;;

  (* {2 Layout} The layouts the state table had; reads handle each of them,
     the internal upgrades bring every one to the current. *)

  type layout =
    | Missing
    | First (* [id] is the step's UUID; no status, last_error, run_at *)
    | Current

  let layout ctx =
    let%lwt tables = Db.find ctx (count_request Dialect.table_exists) (table ()) in
    if tables = 0
    then Lwt.return Missing
    else (
      let%lwt uuid = Db.find ctx column_request (table (), "uuid") in
      Lwt.return (if uuid > 0 then Current else First))
  ;;

  let exec_sql ctx sql = Db.exec ctx (direct T.(unit -->. unit) sql |> unchecked) ()

  (* The first layout to the current one: [id] becomes [uuid], a numeric
     [id] the primary key, the rows [applied]. *)
  let upgrade_uuid_column ctx =
    match%lwt layout ctx with
    | Missing | Current -> Lwt.return_unit
    | First ->
      let kind = kind_of ctx in
      let%lwt primary_key =
        Db.find_opt
          ctx
          (Dialect.request
             Caqti.Template.Request.Direct
             T.(string -->? string)
             Dialect.primary_key_name
           |> unchecked)
          (table ())
      in
      let statements =
        Dialect.upgrade_migration_table
          kind
          ~table:(table ())
          ~primary_key:(CCOption.value ~default:(table () ^ "_pkey") primary_key)
      in
      Log.info (fun m -> m "Upgrading the migration state table %s" (table ()));
      Db.with_transaction ctx (fun ctx -> Lwt_list.iter_s (exec_sql ctx) statements)
  ;;

  (* Veins' own changes to its state table, oldest first. Each one detects
     whether it is needed; they run under the lock before anything writes
     the state ([migrate] once it decided to run, [Import.run]). Reads
     handle every layout, so deciding needs none of them. *)
  let internal_upgrades =
    [ (fun ctx ->
        match%lwt layout ctx with
        | Missing ->
          exec_sql ctx (Dialect.create_migration_table (kind_of ctx) ~table:(table ()))
        | First | Current -> Lwt.return_unit)
    ; upgrade_uuid_column
    ]
  ;;

  let setup ctx = Lwt_list.iter_s (fun upgrade -> upgrade ctx) internal_upgrades

  let row_type =
    T.(
      t2
        (t4 (option int) string string string)
        (t3 Row_status.caqti (option string) ptime))
  ;;

  (* Reading the state must work for a role that may not create tables or
     upgrade it: whether the state table exists, and its rows. *)
  let read_state ctx =
    let read sql =
      let%lwt rows = Db.collect ctx (state_request T.(unit -->* row_type) sql) () in
      Lwt.return
        (CCList.map
           (fun ((id, uuid, namespace, label), (status, last_error, run_at)) ->
              { id
              ; uuid = Id.create uuid
              ; namespace = Namespace.create namespace
              ; label
              ; status
              ; last_error
              ; run_at = Some run_at
              })
           rows)
    in
    match%lwt layout ctx with
    | Missing -> Lwt.return (false, [])
    | First -> Lwt.map (fun rows -> true, rows) (read Dialect.select_state_rows_v1)
    | Current -> Lwt.map (fun rows -> true, rows) (read Dialect.select_state_rows)
  ;;

  let read_rows ctx = Lwt.map snd (read_state ctx)

  let write_row
        ?(if_missing = false)
        ctx
        ~namespace
        ~id
        ~label
        ~status
        ~last_error
        ~run_at
    =
    let n = now () in
    let request =
      state_request
        T.(
          t2
            (t4 string string string Row_status.caqti)
            (t4 (option string) (option ptime) ptime ptime)
          -->. unit)
        (if if_missing
         then Dialect.insert_step_row_if_missing
         else Dialect.upsert_step_row)
    in
    Db.exec
      ctx
      request
      ((Id.value id, Namespace.value namespace, label, status), (last_error, run_at, n, n))
  ;;

  let other_tables ctx =
    let%lwt tables =
      Db.collect
        ctx
        (Dialect.request
           Caqti.Template.Request.Direct
           T.(unit -->* string)
           (fun kind -> Dialect.list_tables kind)
         |> unchecked)
        ()
    in
    Lwt.return
      (CCList.exists (fun name -> not (CCString.equal_caseless name (table ()))) tables)
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
        let%lwt () = exec_sql ctx sql in
        record ctx)
    in
    if check_fk then run () else with_fk_disabled ctx run
  ;;

  (* A step without SQL for [kind] was refused before: a bug here. *)
  let sql_for kind label sql =
    match Sql.for_kind sql kind with
    | Some sql -> sql
    | None ->
      raise
        (Error.Exn
           (Error.Migration_failed
              (Format.asprintf "Step '%s' has no %s SQL" label (kind_name kind))))
  ;;

  (* Runs one step with its row. A failure leaves a [failed] row (written
     after the step's transaction rolled back) and is returned. A lost
     connection says nothing about the step: it is raised, no row written,
     and the step stays pending for the next run. *)
  let run_step ctx kind namespace ({ Resolved.id; label; up; check_fk; _ } : Resolved.t) =
    Log.debug (fun m -> m "Applying step '%s' (%s)" label (Id.show id));
    Lwt.catch
      (fun () ->
         let%lwt () =
           run_statement ctx ~check_fk (sql_for kind label up) (fun ctx ->
             write_row
               ctx
               ~namespace
               ~id
               ~label
               ~status:Row_status.Applied
               ~last_error:None
               ~run_at:(Some (now ())))
         in
         Lwt_result.return ())
      (function
        | exn when Db.is_connection_error exn -> Lwt.reraise exn
        | exn ->
          let error = Printexc.to_string exn in
          let msg =
            Format.asprintf
              "Step '%s' (%s) of migration '%s' failed: %s"
              label
              (Id.show id)
              (Namespace.show namespace)
              error
          in
          Log.err (fun m -> m "%s" msg);
          Lwt.catch
            (fun () ->
               let%lwt () =
                 write_row
                   ctx
                   ~namespace
                   ~id
                   ~label
                   ~status:Row_status.Failed
                   ~last_error:(Some error)
                   ~run_at:(Some (now ()))
               in
               Lwt_result.fail (Error.Migration_failed msg))
            (fun exn ->
               let msg =
                 Format.asprintf
                   "%s; recording the failure failed too: %s"
                   msg
                   (Printexc.to_string exn)
               in
               Log.err (fun m -> m "%s" msg);
               Lwt_result.fail (Error.Migration_failed msg)))
  ;;

  (* Stops at the first failure. *)
  let rec run_steps ctx kind = function
    | [] -> Lwt_result.return ()
    | (namespace, step) :: rest ->
      (match%lwt run_step ctx kind namespace step with
       | Ok () -> run_steps ctx kind rest
       | Error _ as error -> Lwt.return error)
  ;;

  let pending_steps rows migrations =
    let with_row = id_set (CCList.map (fun (r : row) -> r.uuid) rows) in
    CCList.flat_map
      (fun (mig : t) ->
         CCList.filter_map
           (fun ({ Resolved.id; _ } as step) ->
              if is_in with_row id then None else Some (mig.namespace, step))
           (resolve_steps mig))
      migrations
  ;;

  let log_pending steps =
    CCList.group_succ ~eq:(fun (a, _) (b, _) -> Namespace.equal a b) steps
    |> CCList.iter (function
      | [] -> ()
      | (namespace, _) :: _ as steps ->
        Log.info (fun m ->
          m
            "Applying %d step(s) for migration '%s'"
            (CCList.length steps)
            (Namespace.show namespace)))
  ;;

  let run_pending ctx kind rows migrations =
    match pending_steps rows migrations with
    | [] ->
      Log.info (fun m -> m "No pending steps");
      Lwt_result.return ()
    | steps ->
      log_pending steps;
      run_steps ctx kind steps
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
      Lwt.try_bind
        f
        (fun result ->
           let%lwt () = set timeout in
           Lwt.return result)
        (fun exn ->
           (* the run's error matters, not the restore's on what is likely
              the same broken connection *)
           let%lwt () =
             Lwt.catch
               (fun () -> set timeout)
               (fun restore ->
                  Log.warn (fun m ->
                    m
                      "Restoring the statement timeout failed: %s"
                      (Printexc.to_string restore));
                  Lwt.return_unit)
           in
           Lwt.reraise exn)
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

  (* The caller runs [setup] before it writes the state. *)
  let with_ctx ?(role = Entity.Role.owner) db_label f =
    Db.connection_ctx ~role db_label (fun ctx ->
      without_statement_timeout ctx (fun () -> with_lock ctx (fun () -> f ctx)))
  ;;
end

(* {1 Applications} *)

type out_of_order =
  { namespace : Namespace.t
  ; newest_applied : Namespace.t
  }

module Out_of_order = struct
  type t = out_of_order =
    { namespace : Namespace.t
    ; newest_applied : Namespace.t
    }
end

type out_of_order_policy =
  [ `Warn
  | `Fail
  ]

let pp_namespaces f namespaces =
  Format.pp_print_string f (CCString.concat ", " (CCList.map Namespace.show namespaces))
;;

module Report = struct
  type t =
    { label : Entity.Label.t
    ; set : string
    ; dialect : Dialect.kind
    ; pending : (Namespace.t * string list) list
    ; out_of_order : out_of_order list
    ; failed : row list
    ; orphaned : row list
    ; unsupported : (Namespace.t * string list) list
    ; uninitialized : bool
    }

  let pending_counts (t : t) =
    CCList.map (fun (namespace, labels) -> namespace, CCList.length labels) t.pending
  ;;

  let pending_total t =
    CCList.fold_left (fun n (_, count) -> n + count) 0 (pending_counts t)
  ;;

  let pp f (t : t) =
    Format.fprintf
      f
      "@[<v>%a (set %s, %s): %s"
      Entity.Label.pp
      t.label
      t.set
      (kind_name t.dialect)
      (if t.uninitialized
       then "uninitialized: no migration state, but other tables; import it first"
       else if not (CCList.is_empty t.failed)
       then "a failed step blocks the migrations"
       else if not (CCList.is_empty t.unsupported)
       then "pending steps without SQL for the dialect"
       else if not (CCList.is_empty t.pending)
       then Format.asprintf "%d pending step(s)" (pending_total t)
       else "up to date");
    CCList.iter
      (fun (namespace, labels) ->
         Format.fprintf
           f
           "@,  pending: '%a': %s"
           Namespace.pp
           namespace
           (CCString.concat ", " labels))
      t.pending;
    CCList.iter
      (fun { namespace; newest_applied } ->
         Format.fprintf
           f
           "@,  out of order: '%a' comes before '%a', which is applied"
           Namespace.pp
           namespace
           Namespace.pp
           newest_applied)
      t.out_of_order;
    CCList.iter
      (fun (row : row) ->
         Format.fprintf f "@,  failed: %a" (pp_failed_row ~dialect:t.dialect) row)
      t.failed;
    CCList.iter
      (fun (namespace, steps) ->
         Format.fprintf
           f
           "@,  no %s SQL: '%a': %s"
           (kind_name t.dialect)
           Namespace.pp
           namespace
           (CCString.concat ", " steps))
      t.unsupported;
    (match t.orphaned with
     | [] -> ()
     | orphaned ->
       Format.fprintf
         f
         "@,  orphaned: %d row(s) outside the set (%d failed): %a"
         (CCList.length orphaned)
         (CCList.count is_failed_row orphaned)
         pp_namespaces
         (CCList.sort_uniq
            ~cmp:Namespace.compare
            (CCList.map (fun (r : row) -> r.namespace) orphaned)));
    Format.fprintf f "@]"
  ;;

  let show = Format.asprintf "%a" pp
end

module Refusal = struct
  type t =
    | Duplicates of string
    | Missing_dialect of (Namespace.t * string list) list
    | Uninitialized
    | Failed of row list
    | Out_of_order of out_of_order list

  let pp ~dialect f = function
    | Duplicates msg -> Format.pp_print_string f msg
    | Missing_dialect missing ->
      Format.pp_print_string f (unsupported_message dialect missing)
    | Uninitialized ->
      Format.pp_print_string
        f
        "the database has tables but no migration state: import it first"
    | Failed rows -> Format.pp_print_string f (failed_message ~dialect rows)
    | Out_of_order list ->
      Format.fprintf
        f
        "@[<v>migrations out of order (the set allows none):%a@,\
         Move each one's written_at after the newest applied migration (its namespace \
         and step ids stay), or allow it for this run with --allow-out-of-order \
         <namespace> (or ALLOW_OUT_OF_ORDER).@]"
        (fun f ->
           CCList.iter (fun { namespace; newest_applied } ->
             Format.fprintf
               f
               "@,  '%a' comes before '%a', which is applied"
               Namespace.pp
               namespace
               Namespace.pp
               newest_applied))
        list
  ;;

  let show ~dialect = Format.asprintf "%a" (pp ~dialect)

  let summary = function
    | Duplicates msg -> msg
    | Missing_dialect missing ->
      Format.asprintf
        "pending steps without SQL for the dialect: %a"
        pp_namespaces
        (CCList.map fst missing)
    | Uninitialized ->
      "uninitialized: no migration state, but other tables; import it first"
    | Failed rows ->
      Format.asprintf
        "%d failed step(s), repair by hand: %s"
        (CCList.length rows)
        (CCString.concat
           ", "
           (CCList.map
              (fun (row : row) ->
                 Format.asprintf
                   "%s (%s, '%s')"
                   (Id.show row.uuid)
                   (Namespace.show row.namespace)
                   row.label)
              rows))
    | Out_of_order list ->
      Format.asprintf
        "out of order: %a"
        pp_namespaces
        (CCList.map (fun ({ namespace; _ } : out_of_order) -> namespace) list)
  ;;
end

module Dry_run = struct
  type t =
    { report : Report.t
    ; allowed : out_of_order list
    ; refusal : Refusal.t option
    }

  let pp f { report; allowed; refusal } =
    Format.fprintf f "@[<v>%a" Report.pp report;
    CCList.iter
      (fun { namespace; newest_applied } ->
         Format.fprintf
           f
           "@,  allowed out of order: '%a' runs after '%a'"
           Namespace.pp
           namespace
           Namespace.pp
           newest_applied)
      allowed;
    (match refusal with
     | None ->
       if CCList.is_empty report.Report.pending
       then Format.fprintf f "@,migrate has nothing to run"
       else Format.fprintf f "@,migrate would run the pending steps"
     | Some refusal ->
       Format.fprintf
         f
         "@,migrate would refuse: %a"
         (Refusal.pp ~dialect:report.Report.dialect)
         refusal);
    Format.fprintf f "@]"
  ;;

  let show = Format.asprintf "%a" pp

  (* Everything [migrate] decides before it runs, from the state it read,
     and the set in the order it runs. *)
  let decide
        ?(allow_out_of_order = [])
        ~label
        ~set
        ~out_of_order:policy
        ~dialect
        ~state_table
        ~other_tables
        ~rows
        migrations
    =
    let ordered = order migrations in
    let duplicated = duplicates_message (duplicates migrations) in
    let ids = id_set (CCList.flat_map step_ids ordered) in
    let with_row = id_set (CCList.map (fun (r : row) -> r.uuid) rows) in
    let applied = applied_set rows in
    let pending =
      CCList.filter_map
        (fun (mig : migration) ->
           match
             CCList.filter_map
               (fun { Resolved.id; label; _ } ->
                  if is_in with_row id then None else Some label)
               (resolve_steps mig)
           with
           | [] -> None
           | labels -> Some (mig.namespace, labels))
        ordered
    in
    let failed =
      CCList.filter (fun (r : row) -> is_failed_row r && is_in ids r.uuid) rows
    in
    let orphaned = CCList.filter (fun (r : row) -> not (is_in ids r.uuid)) rows in
    let missing = unsupported dialect with_row ordered in
    let newest_applied =
      CCList.fold_left
        (fun newest mig ->
           if CCList.exists (fun id -> is_in applied id) (step_ids mig)
           then Some mig.namespace
           else newest)
        None
        ordered
    in
    let out_of_order =
      match newest_applied with
      | None -> []
      | Some newest ->
        let rec before : migration list -> out_of_order list = function
          | [] -> []
          | mig :: _ when Namespace.equal mig.namespace newest -> []
          | mig :: rest ->
            if
              CCList.exists
                (fun (namespace, _) -> Namespace.equal namespace mig.namespace)
                pending
            then { namespace = mig.namespace; newest_applied = newest } :: before rest
            else before rest
        in
        before ordered
    in
    let named ({ namespace; _ } : out_of_order) =
      CCList.mem ~eq:Namespace.equal namespace allow_out_of_order
    in
    let allowed, refused =
      match policy with
      | `Warn -> out_of_order, []
      | `Fail -> CCList.partition named out_of_order
    in
    let report =
      { Report.label
      ; set
      ; dialect
      ; pending
      ; out_of_order
      ; failed
      ; orphaned
      ; unsupported = missing
      ; uninitialized = (not state_table) && other_tables
      }
    in
    let refusal =
      match duplicated, missing, report.Report.uninitialized, failed, refused with
      | Some msg, _, _, _, _ -> Some (Refusal.Duplicates msg)
      | None, (_ :: _ as missing), _, _, _ -> Some (Refusal.Missing_dialect missing)
      | None, [], true, _, _ -> Some Refusal.Uninitialized
      | None, [], false, (_ :: _ as failed), _ -> Some (Refusal.Failed failed)
      | None, [], false, [], (_ :: _ as refused) -> Some (Refusal.Out_of_order refused)
      | None, [], false, [], [] -> None
    in
    { report; allowed; refusal }, ordered
  ;;

  let of_state
        ?allow_out_of_order
        ~label
        ~set
        ~out_of_order
        ~dialect
        ~state_table
        ~other_tables
        ~rows
        migrations
    =
    fst
      (decide
         ?allow_out_of_order
         ~label
         ~set
         ~out_of_order
         ~dialect
         ~state_table
         ~other_tables
         ~rows
         migrations)
  ;;
end

module Status = struct
  type t =
    | Ready
    | Pending of Report.t
    | Blocked of Refusal.t * Report.t

  let of_dry_run ({ Dry_run.report; refusal; _ } : Dry_run.t) =
    match refusal with
    | Some refusal -> Blocked (refusal, report)
    | None -> if CCList.is_empty report.Report.pending then Ready else Pending report
  ;;

  let is_ready = function
    | Ready -> true
    | Pending _ | Blocked _ -> false
  ;;

  let pp f = function
    | Ready -> Format.pp_print_string f "up to date"
    | Pending report ->
      Format.fprintf
        f
        "%d pending step(s): %s"
        (Report.pending_total report)
        (CCString.concat
           ", "
           (CCList.map
              (fun (namespace, count) ->
                 Format.asprintf "%s (%d)" (Namespace.show namespace) count)
              (Report.pending_counts report)))
    | Blocked (refusal, _) -> Format.fprintf f "blocked, %s" (Refusal.summary refusal)
  ;;

  let show = Format.asprintf "%a" pp
end

module Import = struct
  type entry =
    { namespace : Namespace.t
    ; applied : int
    ; failed : string option
    }

  module type Source = sig
    val name : string
    val read : Caqti_lwt.connection -> (entry list, Caqti.Error.t) Lwt_result.t
  end

  module Report = struct
    type t =
      { applied : (Namespace.t * int) list
      ; failed : (Namespace.t * string) list
      ; unknown : Namespace.t list
      ; too_large : (Namespace.t * int * int) list
      }

    let pp f { applied; failed; unknown; too_large } =
      Format.fprintf
        f
        "imported %d applied step(s)%s, %d failed step(s)%s"
        (CCList.fold_left (fun n (_, k) -> n + k) 0 applied)
        (match applied with
         | [] -> ""
         | applied ->
           Format.asprintf
             " (%s)"
             (CCString.concat
                ", "
                (CCList.map
                   (fun (namespace, n) ->
                      Format.asprintf "%s: %d" (Namespace.show namespace) n)
                   applied)))
        (CCList.length failed)
        (match failed with
         | [] -> ""
         | failed ->
           Format.asprintf
             " (%s)"
             (CCString.concat
                ", "
                (CCList.map
                   (fun (namespace, label) ->
                      Format.asprintf "%s: '%s'" (Namespace.show namespace) label)
                   failed)));
      if not (CCList.is_empty unknown)
      then
        Format.fprintf
          f
          "; skipped namespaces the set doesn't know: %a"
          pp_namespaces
          unknown;
      if not (CCList.is_empty too_large)
      then
        Format.fprintf
          f
          "; counters larger than the step count: %s"
          (CCString.concat
             ", "
             (CCList.map
                (fun (namespace, counter, steps) ->
                   Format.asprintf "%s (%d > %d)" (Namespace.show namespace) counter steps)
                too_large))
    ;;

    let show = Format.asprintf "%a" pp
  end

  let plan ~source (migrations : migration list) ~existing entries =
    let existing = id_set existing in
    let row namespace ({ Resolved.id; label; _ } : Resolved.t) status last_error =
      { id = None; uuid = id; namespace; label; status; last_error; run_at = None }
    in
    CCList.fold_left
      (fun ((report : Report.t), rows) ({ namespace; applied; failed } : entry) ->
         match
           CCList.find_opt
             (fun (m : migration) -> Namespace.equal m.namespace namespace)
             migrations
         with
         | None ->
           { report with Report.unknown = report.Report.unknown @ [ namespace ] }, rows
         | Some mig ->
           let steps = resolve_steps mig in
           let total = CCList.length steps in
           let too_large =
             if applied > total
             then report.Report.too_large @ [ namespace, applied, total ]
             else report.Report.too_large
           in
           let new_applied =
             CCList.take (max 0 applied) steps
             |> CCList.filter (fun ({ Resolved.id; _ } : Resolved.t) ->
               not (is_in existing id))
             |> CCList.map (fun step -> row namespace step Row_status.Applied None)
           in
           let new_failed =
             match failed, CCList.nth_opt steps (max 0 applied) with
             | Some message, Some step when not (is_in existing step.Resolved.id) ->
               [ row
                   namespace
                   step
                   Row_status.Failed
                   (Some (Format.asprintf "%s: %s" source message))
               ]
             | Some _, _ | None, _ -> []
           in
           ( { Report.applied =
                 (match new_applied with
                  | [] -> report.Report.applied
                  | rows -> report.Report.applied @ [ namespace, CCList.length rows ])
             ; failed =
                 report.Report.failed
                 @ CCList.map (fun (r : row) -> namespace, r.label) new_failed
             ; unknown = report.Report.unknown
             ; too_large
             }
           , rows @ new_applied @ new_failed ))
      ({ Report.applied = []; failed = []; unknown = []; too_large = [] }, [])
      entries
  ;;

  let counter_state ?table () =
    let table =
      match table with
      | None -> "core_migration_state"
      | Some table when Dialect.is_identifier table -> table
      | Some table ->
        invalid_arg
          (Format.asprintf
             "Migration.Import.counter_state: %S is not a plain table name"
             table)
    in
    let module Source = struct
      let name = table

      let read (module C : Caqti_lwt.CONNECTION) =
        let open Lwt_result.Syntax in
        let* count =
          C.find
            (Dialect.request
               Caqti.Template.Request.Direct
               T.(string -->! int)
               Dialect.table_exists)
            table
        in
        if count = 0
        then Lwt_result.return []
        else
          let+ rows =
            C.collect_list
              (Dialect.request
                 Caqti.Template.Request.Direct
                 T.(unit -->* t3 string (option int) bool)
                 (fun (_ : Dialect.kind) ->
                    Format.asprintf "SELECT namespace, version, dirty FROM %s" table))
              ()
          in
          CCList.map
            (fun (namespace, version, dirty) ->
               let applied = CCOption.value ~default:0 version in
               { namespace = Namespace.create namespace
               ; applied
               ; failed =
                   CCOption.return_if
                     dirty
                     (Format.asprintf "marked dirty after %d step(s)" applied)
               })
            rows
      ;;
    end
    in
    (module Source : Source)
  ;;
end

module Command = struct
  type action =
    | Up of Namespace.t list
    | Dry_run of Namespace.t list
    | Status
    | Check

  let usage =
    "usage: [up | dry-run] [--allow-out-of-order <namespace>...]... | status | check"
  ;;

  let parse_allowed args =
    let rec go allowed = function
      | [] -> Ok allowed
      | "--allow-out-of-order" :: rest ->
        let names, rest =
          CCList.take_drop_while (fun arg -> not (CCString.prefix ~pre:"--" arg)) rest
        in
        (match names with
         | [] -> Error usage
         | names -> go (allowed @ CCList.map Namespace.create names) rest)
      | (_ : string) :: _ -> Error usage
    in
    go [] args
  ;;

  let parse = function
    | [] -> Ok (Up [])
    | "up" :: rest -> CCResult.map (fun allowed -> Up allowed) (parse_allowed rest)
    | "dry-run" :: rest ->
      CCResult.map (fun allowed -> Dry_run allowed) (parse_allowed rest)
    | [ "status" ] -> Ok Status
    | [ "check" ] -> Ok Check
    | (_ : string list) -> Error usage
  ;;

  let allowed_of_env = function
    | None -> []
    | Some value ->
      CCString.split_on_char ',' value
      |> CCList.flat_map (CCString.split_on_char ' ')
      |> CCList.flat_map (CCString.split_on_char '\t')
      |> CCList.flat_map (CCString.split_on_char '\n')
      |> CCList.map CCString.trim
      |> CCList.filter (fun s -> not (CCString.is_empty s))
      |> CCList.map Namespace.create
  ;;

  let env_variable = "ALLOW_OUT_OF_ORDER"
end

module type Import_sig = sig
  val run
    :  ?role:_ Entity.Role.t
    -> source:(module Import.Source)
    -> Entity.Label.t
    -> (Import.Report.t, Error.t) Lwt_result.t
end

module type App_sig = sig
  val migrate
    :  ?role:_ Entity.Role.t
    -> ?allow_out_of_order:Namespace.t list
    -> Entity.Label.t
    -> (unit, Error.t) Lwt_result.t

  val dry_run
    :  ?role:_ Entity.Role.t
    -> ?allow_out_of_order:Namespace.t list
    -> Entity.Label.t
    -> (Dry_run.t, Error.t) Lwt_result.t

  val ready : ?role:_ Entity.Role.t -> Entity.Label.t -> (Status.t, Error.t) Lwt_result.t
  val report : ?role:_ Entity.Role.t -> Entity.Label.t -> Report.t Lwt.t

  val check
    :  ?role:_ Entity.Role.t
    -> ?policy:[ `Fail | `Warn | `Skip ]
    -> Entity.Label.t
    -> (unit, Status.t) Lwt_result.t

  val ensure_clean
    :  ?role:_ Entity.Role.t
    -> ?skip:bool
    -> Entity.Label.t list
    -> unit Lwt.t

  val command
    :  ?role:_ Entity.Role.t
    -> ?out:Format.formatter
    -> Entity.Label.t list
    -> string list
    -> int Lwt.t

  val command_exit
    :  ?role:_ Entity.Role.t
    -> ?out:Format.formatter
    -> Entity.Label.t list
    -> string list
    -> 'a Lwt.t

  module Import : Import_sig
end

(* What an application's set is for one database. *)
module type Set_for = sig
  val set_for : Entity.Label.t -> string * out_of_order_policy * (unit -> t list)
end

module Make_app (Db : Pools_sig.Sig) (Set : Set_for) : App_sig = struct
  module Runner = Make_internal (Db)

  (* What a run raises instead of returning, as a returned error. *)
  let as_result label f =
    Lwt.catch f (function[@warning "-4"]
      | Error.Exn error -> Lwt_result.fail error
      | exn when Db.is_connection_error exn ->
        Lwt_result.fail
          (Error.Connection_failed
             (Format.asprintf "%s: %s" (Entity.Label.show label) (Printexc.to_string exn)))
      | Error.Failed _ as exn ->
        Lwt_result.fail
          (Error.Migration_failed
             (Format.asprintf
                "Migrating '%s' failed: %s"
                (Entity.Label.show label)
                (Printexc.to_string exn)))
      | exn -> Lwt.reraise exn)
  ;;

  let analyse ?allow_out_of_order ctx label =
    let set, policy, migrations = Set.set_for label in
    let%lwt state_table, rows = Runner.read_state ctx in
    let%lwt other_tables =
      if state_table then Lwt.return false else Runner.other_tables ctx
    in
    let dry_run, ordered =
      Dry_run.decide
        ?allow_out_of_order
        ~label
        ~set
        ~out_of_order:policy
        ~dialect:(Runner.kind_of ctx)
        ~state_table
        ~other_tables
        ~rows
        (migrations ())
    in
    Lwt.return (dry_run, ordered, rows)
  ;;

  let log_out_of_order ~policy ~allow_out_of_order (dry_run : Dry_run.t) =
    CCList.iter
      (fun ({ namespace; newest_applied } : out_of_order) ->
         Log.warn (fun m ->
           m
             "%s migration '%s' out of order, after '%s' was applied"
             (match policy with
              | `Warn -> "Running"
              | `Fail -> "Allowed to run")
             (Namespace.show namespace)
             (Namespace.show newest_applied)))
      dry_run.Dry_run.allowed;
    CCList.iter
      (fun namespace ->
         if
           not
             (CCList.exists
                (fun ({ namespace = n; _ } : out_of_order) -> Namespace.equal n namespace)
                dry_run.Dry_run.report.Report.out_of_order)
         then
           Log.info (fun m ->
             m
               "'%s' is allowed out of order but isn't (applied already, or in order): \
                ignored"
               (Namespace.show namespace)))
      allow_out_of_order
  ;;

  let migrate ?role ?(allow_out_of_order = []) label =
    let%lwt result =
      as_result label
      @@ fun () ->
      Runner.with_ctx ?role label
      @@ fun ctx ->
      (* decided before the upgrades: a refused run doesn't create the state
         table, so an uninitialized database stays one until imported *)
      let%lwt dry_run, ordered, rows = analyse ~allow_out_of_order ctx label in
      let (_ : string), policy, (_ : unit -> t list) = Set.set_for label in
      match dry_run.Dry_run.refusal with
      | Some refusal ->
        Lwt_result.fail
          (Error.Migration_failed
             (Refusal.show ~dialect:dry_run.Dry_run.report.Report.dialect refusal))
      | None ->
        log_out_of_order ~policy ~allow_out_of_order dry_run;
        let%lwt () = Runner.setup ctx in
        Runner.run_pending ctx dry_run.Dry_run.report.Report.dialect rows ordered
    in
    (match result with
     | Ok () ->
       Log.info (fun m -> m "Database '%s' is up to date" (Entity.Label.show label))
     | Error error ->
       Log.err (fun m ->
         m "Migrating '%s' failed: %a" (Entity.Label.show label) Error.pp error));
    Lwt.return result
  ;;

  let dry_run ?role ?allow_out_of_order label =
    as_result label
    @@ fun () ->
    Runner.with_read_ctx ?role label
    @@ fun ctx ->
    let%lwt dry_run, (_ : t list), (_ : row list) =
      analyse ?allow_out_of_order ctx label
    in
    Lwt_result.return dry_run
  ;;

  (* The state without allowances: what [migrate] would do with no flag. *)
  let read ?role label =
    Runner.with_read_ctx ?role label
    @@ fun ctx ->
    let%lwt dry_run, (_ : t list), (_ : row list) = analyse ctx label in
    Lwt.return dry_run
  ;;

  let report ?role label = Lwt.map (fun d -> d.Dry_run.report) (read ?role label)

  let ready ?role label =
    as_result label (fun () ->
      let%lwt dry_run = read ?role label in
      Lwt_result.return (Status.of_dry_run dry_run))
  ;;

  (* Logs the state of a label read at startup; [None] when it is ready.
     What prevents reading it (an unreachable database) is logged and
     returned. *)
  let startup_status ~level ?role label =
    match%lwt as_result label (fun () -> Lwt_result.ok (read ?role label)) with
    | Error error ->
      Log.msg level (fun m ->
        m
          "Reading the migration state of '%s' failed: %a"
          (Entity.Label.show label)
          Error.pp
          error);
      Lwt_result.fail error
    | Ok dry_run ->
      let report = dry_run.Dry_run.report in
      (match Status.of_dry_run dry_run with
       | Status.Ready ->
         if
           not
             (CCList.is_empty report.Report.out_of_order
              && CCList.is_empty report.Report.orphaned)
         then Log.info (fun m -> m "%a" Report.pp report);
         Lwt_result.return None
       | (Status.Pending _ | Status.Blocked _) as status ->
         Log.msg level (fun m -> m "%a" Dry_run.pp dry_run);
         Lwt_result.return (Some status))
  ;;

  let check ?role ?(policy = `Fail) label =
    match policy with
    | `Skip -> Lwt_result.return ()
    | `Warn ->
      let%lwt (_ : (Status.t option, Error.t) result) =
        startup_status ~level:Logs.Warning ?role label
      in
      Lwt_result.return ()
    | `Fail ->
      (match%lwt startup_status ~level:Logs.Error ?role label with
       | Ok None -> Lwt_result.return ()
       | Ok (Some status) -> Lwt_result.fail status
       | Error error -> raise (Error.Exn error))
  ;;

  let ensure_clean ?role ?(skip = false) labels =
    if skip
    then Lwt.return_unit
    else (
      let%lwt unclean =
        Lwt_list.filter_map_s
          (fun label ->
             let%lwt status = startup_status ~level:Logs.Error ?role label in
             Lwt.return
               (match status with
                | Ok status ->
                  CCOption.map
                    (fun status -> Entity.Label.value label, Status.show status)
                    status
                | Error error -> raise (Error.Exn error)))
          labels
      in
      match unclean with
      | [] -> Lwt.return_unit
      | unclean -> raise (Error.Exn (Error.Migration_not_clean unclean)))
  ;;

  let allowed_with_env ~out allowed =
    let from_env = Command.allowed_of_env (Sys.getenv_opt Command.env_variable) in
    CCList.iter
      (fun namespace ->
         Format.fprintf
           out
           "allowed out of order: %a (--allow-out-of-order)@."
           Namespace.pp
           namespace)
      allowed;
    CCList.iter
      (fun namespace ->
         Format.fprintf
           out
           "allowed out of order: %a (%s)@."
           Namespace.pp
           namespace
           Command.env_variable)
      from_env;
    CCList.sort_uniq ~cmp:Namespace.compare (allowed @ from_env)
  ;;

  (* Every label, then the worst exit code. *)
  let each labels f =
    let%lwt codes = Lwt_list.map_s f labels in
    Lwt.return (CCList.fold_left max 0 codes)
  ;;

  let guarded out label f =
    Lwt.catch f (fun exn ->
      Format.fprintf out "%a: %s@." Entity.Label.pp label (Printexc.to_string exn);
      Lwt.return 1)
  ;;

  let command ?role ?(out = Format.std_formatter) labels args =
    match Command.parse args with
    | Error usage ->
      Format.fprintf out "%s@." usage;
      Lwt.return 2
    | Ok (Command.Up allowed) ->
      let allow_out_of_order = allowed_with_env ~out allowed in
      each labels (fun label ->
        guarded out label (fun () ->
          match%lwt migrate ?role ~allow_out_of_order label with
          | Ok () ->
            Format.fprintf out "%a: up to date@." Entity.Label.pp label;
            Lwt.return 0
          | Error error ->
            Format.fprintf out "%a: %a@." Entity.Label.pp label Error.pp error;
            Lwt.return 1))
    | Ok (Command.Dry_run allowed) ->
      let allow_out_of_order = allowed_with_env ~out allowed in
      each labels (fun label ->
        guarded out label (fun () ->
          match%lwt dry_run ?role ~allow_out_of_order label with
          | Ok dry_run ->
            Format.fprintf out "%a@." Dry_run.pp dry_run;
            Lwt.return (if CCOption.is_some dry_run.Dry_run.refusal then 1 else 0)
          | Error error ->
            Format.fprintf out "%a: %a@." Entity.Label.pp label Error.pp error;
            Lwt.return 1))
    | Ok Command.Status ->
      each labels (fun label ->
        guarded out label (fun () ->
          let%lwt report = report ?role label in
          Format.fprintf out "%a@." Report.pp report;
          Lwt.return 0))
    | Ok Command.Check ->
      each labels (fun label ->
        guarded out label (fun () ->
          let%lwt dry_run = read ?role label in
          Format.fprintf out "%a@." Dry_run.pp dry_run;
          Lwt.return (if Status.is_ready (Status.of_dry_run dry_run) then 0 else 1)))
  ;;

  let command_exit ?role ?out labels args =
    let%lwt code = command ?role ?out labels args in
    exit code
  ;;

  module Import = struct
    let run ?role ~source:(module Source : Import.Source) label =
      as_result label
      @@ fun () ->
      Runner.with_ctx ?role label
      @@ fun ctx ->
      let (_ : string), (_ : out_of_order_policy), migrations = Set.set_for label in
      let%lwt () = Runner.setup ctx in
      let%lwt entries = Db.query ~needs:Entity.Need.none ctx Source.read in
      let%lwt rows = Runner.read_rows ctx in
      let report, to_insert =
        Import.plan
          ~source:Source.name
          (migrations ())
          ~existing:(CCList.map (fun (r : row) -> r.uuid) rows)
          entries
      in
      let%lwt () =
        Db.with_transaction ctx (fun ctx ->
          Lwt_list.iter_s
            (fun (r : row) ->
               Runner.write_row
                 ~if_missing:true
                 ctx
                 ~namespace:r.namespace
                 ~id:r.uuid
                 ~label:r.label
                 ~status:r.status
                 ~last_error:r.last_error
                 ~run_at:None)
            to_insert)
      in
      Log.info (fun m ->
        m
          "Import from %s into '%s': %a"
          Source.name
          (Entity.Label.show label)
          Import.Report.pp
          report);
      Lwt_result.return report
    ;;
  end
end

module App = struct
  module Make (Db : Pools_sig.Sig) =
    Make_app
      (Db)
      (struct
        let set_for (_ : Entity.Label.t) = "default", `Fail, registered
      end)
end

module Sets = struct
  module type S = sig
    type t

    val all : t list
    val name : t -> string
    val out_of_order : t -> out_of_order_policy
  end

  module Make (S : S) (Db : Pools_sig.Sig) = struct
    let () =
      let names = CCList.map S.name S.all in
      if
        CCList.length (CCList.sort_uniq ~cmp:CCString.compare names)
        <> CCList.length names
      then invalid_arg "Migration.Sets.Make: two sets have the same name"
    ;;

    (* Oldest first. *)
    let registry : (t * string list) list ref = ref []

    let register ~sets (migration : migration) =
      let names = CCList.sort_uniq ~cmp:CCString.compare (CCList.map S.name sets) in
      CCList.iter
        (fun name ->
           if
             CCList.exists
               (fun ((m : migration), names) ->
                  Namespace.equal m.namespace migration.namespace
                  && CCList.mem ~eq:CCString.equal name names)
               !registry
           then
             invalid_arg
               (Format.asprintf
                  "Migration.Sets.register: '%s' is registered twice in set %s"
                  (Namespace.show migration.namespace)
                  name))
        names;
      registry := !registry @ [ migration, names ]
    ;;

    let migrations set =
      let name = S.name set in
      CCList.filter_map
        (fun (m, names) ->
           CCOption.return_if (CCList.mem ~eq:CCString.equal name names) m)
        !registry
      |> order
    ;;

    module App (A : sig
        val set_for : Entity.Label.t -> S.t
      end) =
      Make_app
        (Db)
        (struct
          let set_for label =
            let set = A.set_for label in
            S.name set, S.out_of_order set, fun () -> migrations set
          ;;
        end)
  end
end

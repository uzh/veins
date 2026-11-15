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

module Step = struct
  type t =
    { id : Id.t
    ; label : string
    ; up : string
    ; down : string option
    ; check_fk : bool
    }

  let create ~id ~label ?(check_fk = true) ?down up = { id; label; up; down; check_fk }
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
let step_ids m = CCList.map Step.id m.steps

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
  let table () = Lazy.force table_name

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

  let insert_applied_step ctx namespace { Step.id; label; _ } =
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

  let dialect_kind ctx =
    Db.query
      ~needs:Entity.Need.none
      ctx
      (fun (module Connection : Caqti_lwt.CONNECTION) ->
         Lwt_result.return (Dialect.kind Connection.dialect))
  ;;

  (* [SET FOREIGN_KEY_CHECKS] is session state: [ctx] holds one connection, so
     both toggles and the step run on it. *)
  let with_fk_disabled ctx f =
    let%lwt kind = dialect_kind ctx in
    match Dialect.set_fk_checks kind false with
    | None -> f ()
    | Some (_ : string) ->
      let set enabled =
        Dialect.request
          Caqti.Template.Request.Direct
          T.(unit -->. unit)
          (fun kind -> Dialect.set_fk_checks kind enabled |> CCOption.get_or ~default:"")
        |> unchecked
      in
      let%lwt () = Db.exec ctx (set false) () in
      Lwt.finalize f (fun () -> Db.exec ctx (set true) ())
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

  let run_step_up ctx namespace ({ Step.id; label; up; check_fk; _ } as s) =
    Log.debug (fun m -> m "Applying step '%s' (%s)" label (Id.show id));
    run_statement ctx ~check_fk up (fun ctx -> insert_applied_step ctx namespace s)
  ;;

  let run_step_down ctx { Step.id; label; down; check_fk; _ } =
    match down with
    | None ->
      Log.warn (fun m ->
        m "Step '%s' (%s) has no down migration; skipping" label (Id.show id));
      Lwt.return_unit
    | Some sql ->
      Log.debug (fun m -> m "Reverting step '%s' (%s)" label (Id.show id));
      run_statement ctx ~check_fk sql (fun ctx -> delete_applied_step ctx id)
  ;;

  let failed fmt mig exn =
    let msg =
      Format.asprintf fmt (Namespace.show mig.namespace) (Printexc.to_string exn)
    in
    Log.err (fun m -> m "%s" msg);
    Lwt_result.fail (Error.Migration_failed msg)
  ;;

  let apply_up ctx mig =
    let%lwt applied_ids = get_applied_ids ctx in
    let applied = applied_id_set applied_ids in
    let pending_steps =
      CCList.filter (fun { Step.id; _ } -> not (is_applied applied id)) mig.steps
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
           let%lwt () = Lwt_list.iter_s (run_step_up ctx mig.namespace) pending_steps in
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
        let pause = Float.min 0.5 (timeout -. waited) in
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
    lock_error (fun () -> with_ctx ?role db_label (fun ctx -> apply_up ctx mig))
  ;;

  let mark_applied ?role db_label mig ~steps =
    with_ctx ?role db_label
    @@ fun ctx ->
    let%lwt applied_ids = get_applied_ids ctx in
    let applied = applied_id_set applied_ids in
    let to_mark =
      CCList.take steps mig.steps
      |> CCList.filter (fun { Step.id; _ } -> not (is_applied applied id))
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
      CCList.filter (fun { Step.id; _ } -> is_applied applied_set id) mig.steps
    in
    match CCList.length applied with
    | 0 ->
      Log.info (fun m ->
        m "No applied steps to revert for migration '%s'" (Namespace.show mig.namespace));
      Lwt_result.return ()
    | n ->
      Log.info (fun m ->
        m "Reverting %d step(s) for migration '%s'" n (Namespace.show mig.namespace));
      Lwt.catch
        (fun () ->
           let%lwt () = Lwt_list.iter_s (run_step_down ctx) (CCList.rev applied) in
           Lwt_result.return ())
        (failed "Migration '%s' revert failed: %s" mig)
  ;;

  let run_all ?role ?migrations db_label () =
    lock_error
    @@ fun () ->
    with_ctx ?role db_label
    @@ fun ctx ->
    let rec run = function
      | [] -> Lwt_result.return ()
      | mig :: rest ->
        (match%lwt apply_up ctx mig with
         | Error e -> Lwt_result.fail e
         | Ok () -> run rest)
    in
    run (migrations_for ?migrations db_label)
  ;;

  let status ?role ?migrations db_label () =
    with_read_ctx ?role db_label
    @@ fun ctx ->
    let%lwt applied_rows = get_applied_rows ctx in
    let applied = applied_id_set (CCList.map fst applied_rows) in
    Lwt.return
    @@ CCList.map
         (fun mig ->
            let total = CCList.length mig.steps in
            let n_applied =
              CCList.count (fun { Step.id; _ } -> is_applied applied id) mig.steps
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
           let total = CCList.length mig.steps in
           let applied_count =
             CCList.count (fun { Step.id; _ } -> is_applied applied id) mig.steps
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
    Lwt.return (pending_drifts @ orphan_drifts)
  ;;
end

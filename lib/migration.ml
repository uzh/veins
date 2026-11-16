open Caqti_request.Infix

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

let table_name =
  lazy
    (match Sys.getenv_opt "VEINS_MIGRATION_TABLE" with
     | Some t when not (CCString.is_empty t) -> t
     | _ -> "veins_migration_state")
;;

(* Current wall-clock time as a Ptime.t, safe for Caqti_type.ptime. *)
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
    -> Entity.Label.t
    -> unit
    -> (unit, Error.t) Lwt_result.t

  val up : ?role:_ Entity.Role.t -> Entity.Label.t -> t -> (unit, Error.t) Lwt_result.t
  val down : ?role:_ Entity.Role.t -> Entity.Label.t -> t -> (unit, Error.t) Lwt_result.t
  val check : ?role:_ Entity.Role.t -> Entity.Label.t -> unit -> drift list Lwt.t

  val status
    :  ?role:_ Entity.Role.t
    -> Entity.Label.t
    -> unit
    -> (Namespace.t * int * int) list Lwt.t

  val pending
    :  ?role:_ Entity.Role.t
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
  let migrations_for db_label =
    CCList.filter_map
      (fun (target, mig) -> CCOption.return_if (target_applies_to target db_label) mig)
      !registry
    |> CCList.sort (fun a b -> Ptime.compare a.written_at b.written_at)
  ;;

  let applied_id_set ids =
    let tbl = Hashtbl.create (max 1 (CCList.length ids)) in
    CCList.iter (fun id -> Hashtbl.replace tbl id ()) ids;
    tbl
  ;;

  let is_applied = Hashtbl.mem

  let setup ctx =
    let sql = Db.Config.Dialect.create_migration_table ~table:(table ()) in
    Db.exec ctx (Caqti_type.(unit ->. unit) ~oneshot:true sql |> unchecked) ()
  ;;

  let get_applied_ids ctx =
    let sql = Db.Config.Dialect.select_applied_ids ~table:(table ()) in
    let%lwt ids =
      Db.collect ctx (Caqti_type.(unit ->* string) ~oneshot:true sql |> unchecked) ()
    in
    Lwt.return (CCList.map Id.create ids)
  ;;

  let insert_applied_step ctx namespace { Step.id; label; _ } =
    let n = now () in
    let sql = Db.Config.Dialect.insert_applied_step ~table:(table ()) in
    let req =
      Caqti_type.(t2 (t3 string string string) (t2 ptime ptime) ->. unit)
        ~oneshot:true
        sql
      |> unchecked
    in
    Db.exec ctx req ((Id.value id, Namespace.value namespace, label), (n, n))
  ;;

  let delete_applied_step ctx (step_id : Id.t) =
    let sql = Db.Config.Dialect.delete_applied_step ~table:(table ()) in
    Db.exec
      ctx
      (Caqti_type.(string ->. unit) ~oneshot:true sql |> unchecked)
      (Id.value step_id)
  ;;

  (* [SET FOREIGN_KEY_CHECKS] is session state: [ctx] holds one connection, so
     both toggles and the step run on it. *)
  let with_fk_disabled ctx f =
    if not Db.Config.Dialect.fk_checks_supported
    then f ()
    else (
      let set value =
        Format.asprintf "SET FOREIGN_KEY_CHECKS = %d" value
        |> Caqti_type.(unit ->. unit) ~oneshot:true
        |> unchecked
      in
      let%lwt () = Db.exec ctx (set 0) () in
      Lwt.finalize f (fun () -> Db.exec ctx (set 1) ()))
  ;;

  (* The step and its state row commit together where the dialect has
     transactional DDL (PostgreSQL); MariaDB commits DDL implicitly. *)
  let run_statement ctx ~check_fk sql record =
    let run () =
      Db.with_transaction ctx (fun ctx ->
        let%lwt () =
          Db.exec ctx (Caqti_type.(unit ->. unit) ~oneshot:true sql |> unchecked) ()
        in
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

  let with_ctx ?(role = Entity.Role.owner) db_label f =
    Db.connection_ctx ~role db_label (fun ctx ->
      let%lwt () = setup ctx in
      f ctx)
  ;;

  let up ?role db_label mig = with_ctx ?role db_label (fun ctx -> apply_up ctx mig)

  let down ?role db_label mig =
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

  let run_all ?role db_label () =
    with_ctx ?role db_label
    @@ fun ctx ->
    let rec run = function
      | [] -> Lwt_result.return ()
      | mig :: rest ->
        (match%lwt apply_up ctx mig with
         | Error e -> Lwt_result.fail e
         | Ok () -> run rest)
    in
    run (migrations_for db_label)
  ;;

  let status ?role db_label () =
    with_ctx ?role db_label
    @@ fun ctx ->
    let%lwt applied_ids = get_applied_ids ctx in
    let applied = applied_id_set applied_ids in
    Lwt.return
    @@ CCList.map
         (fun mig ->
            let total = CCList.length mig.steps in
            let n_applied =
              CCList.count (fun { Step.id; _ } -> is_applied applied id) mig.steps
            in
            mig.namespace, n_applied, total)
         (migrations_for db_label)
  ;;

  let pending ?role db_label () =
    let%lwt statuses = status ?role db_label () in
    Lwt.return
    @@ CCList.filter_map
         (fun (ns, applied, total) ->
            let n = total - applied in
            CCOption.return_if (n > 0) (ns, n))
         statuses
  ;;

  let check ?role db_label () =
    with_ctx ?role db_label
    @@ fun ctx ->
    let sql = Db.Config.Dialect.select_applied_rows ~table:(table ()) in
    let req = Caqti_type.(unit ->* t2 string string) ~oneshot:true sql |> unchecked in
    let%lwt raw_rows = Db.collect ctx req () in
    let applied_rows =
      CCList.map (fun (id, ns) -> Id.create id, Namespace.create ns) raw_rows
    in
    let applied = applied_id_set (CCList.map fst applied_rows) in
    let migs = migrations_for db_label in
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

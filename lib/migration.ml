open Caqti_request.Infix

let src = Logs.Src.create "veins.migration"

module Log = (val Logs.src_log src : Logs.LOG)

module Id = struct
  type t = string

  let create s = s
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
    (match Sys.getenv_opt "VENA_MIGRATION_TABLE" with
     | Some t when not (CCString.is_empty t) -> t
     | _ -> "vena_migration_state")
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
  val run_all : Entity.Label.t -> unit -> (unit, Error.t) Lwt_result.t
  val up : Entity.Label.t -> t -> (unit, Error.t) Lwt_result.t
  val down : Entity.Label.t -> t -> (unit, Error.t) Lwt_result.t
  val check : Entity.Label.t -> unit -> drift list Lwt.t
  val status : Entity.Label.t -> unit -> (Namespace.t * int * int) list Lwt.t
  val pending : Entity.Label.t -> unit -> (Namespace.t * int) list Lwt.t
end

module Make (Db : Pools_sig.Sig) : RunnerSig = struct
  (* Return migrations targeting [db_label], sorted by written_at ascending. *)
  let migrations_for db_label =
    CCList.filter_map
      (fun (target, mig) -> CCOption.return_if (target_applies_to target db_label) mig)
      !registry
    |> CCList.sort (fun a b -> Ptime.compare a.written_at b.written_at)
  ;;

  (* Build a hash set of applied step IDs for O(1) membership tests. *)
  let applied_id_set ids =
    let tbl = Hashtbl.create (max 1 (CCList.length ids)) in
    CCList.iter (fun id -> Hashtbl.replace tbl id ()) ids;
    tbl
  ;;

  let is_applied = Hashtbl.mem

  let setup db_label =
    let sql = Db.Config.Dialect.create_migration_table ~table:(Lazy.force table_name) in
    let req = Caqti_type.(unit ->. unit) ~oneshot:true sql in
    Db.exec db_label req ()
  ;;

  let get_applied_ids db_label =
    let sql = Db.Config.Dialect.select_applied_ids ~table:(Lazy.force table_name) in
    let req = Caqti_type.(unit ->* string) ~oneshot:true sql in
    let%lwt ids = Db.collect db_label req () in
    Lwt.return (CCList.map Id.create ids)
  ;;

  let insert_applied_step db_label namespace { Step.id; label; _ } =
    let n = now () in
    let sql = Db.Config.Dialect.insert_applied_step ~table:(Lazy.force table_name) in
    let req =
      Caqti_type.(t2 (t3 string string string) (t2 ptime ptime) ->. unit)
        ~oneshot:true
        sql
    in
    Db.exec db_label req ((Id.value id, Namespace.value namespace, label), (n, n))
  ;;

  let delete_applied_step db_label (step_id : Id.t) =
    let sql = Db.Config.Dialect.delete_applied_step ~table:(Lazy.force table_name) in
    let req = Caqti_type.(string ->. unit) ~oneshot:true sql in
    Db.exec db_label req (Id.value step_id)
  ;;

  let with_fk_disabled db_label f =
    if not Db.Config.Dialect.fk_checks_supported
    then f ()
    else (
      let off = Caqti_type.(unit ->. unit) ~oneshot:true "SET FOREIGN_KEY_CHECKS = 0" in
      let on = Caqti_type.(unit ->. unit) ~oneshot:true "SET FOREIGN_KEY_CHECKS = 1" in
      let%lwt () = Db.exec db_label off () in
      Lwt.finalize f (fun () -> Db.exec db_label on ()))
  ;;

  let run_step_up db_label namespace ({ Step.id; label; up; check_fk; _ } as s) =
    Log.debug (fun m -> m "Applying step '%s' (%s)" label (Id.show id));
    let do_exec () =
      let req = Caqti_type.(unit ->. unit) ~oneshot:true up in
      let%lwt () = Db.exec db_label req () in
      insert_applied_step db_label namespace s
    in
    if check_fk then do_exec () else with_fk_disabled db_label do_exec
  ;;

  let run_step_down db_label { Step.id; label; down; check_fk; _ } =
    match down with
    | None ->
      Log.warn (fun m ->
        m "Step '%s' (%s) has no down migration; skipping" label (Id.show id));
      Lwt.return_unit
    | Some sql ->
      Log.debug (fun m -> m "Reverting step '%s' (%s)" label (Id.show id));
      let do_exec () =
        let req = Caqti_type.(unit ->. unit) ~oneshot:true sql in
        let%lwt () = Db.exec db_label req () in
        delete_applied_step db_label id
      in
      if check_fk then do_exec () else with_fk_disabled db_label do_exec
  ;;

  let apply_up db_label mig =
    let%lwt applied_ids = get_applied_ids db_label in
    let applied = applied_id_set applied_ids in
    let pending_steps =
      CCList.filter (fun { Step.id; _ } -> not (is_applied applied id)) mig.steps
    in
    let n = CCList.length pending_steps in
    if n = 0
    then (
      Log.info (fun m ->
        m "No pending steps for migration '%s'" (Namespace.show mig.namespace));
      Lwt_result.return ())
    else (
      Log.info (fun m ->
        m "Applying %d step(s) for migration '%s'" n (Namespace.show mig.namespace));
      (Lwt.catch
         (fun () ->
            let%lwt () =
              Lwt_list.iter_s (run_step_up db_label mig.namespace) pending_steps
            in
            Lwt_result.return ())
         (fun exn ->
            let msg =
              Format.asprintf
                "Migration '%s' failed: %s"
                (Namespace.show mig.namespace)
                (Printexc.to_string exn)
            in
            Log.err (fun m -> m "%s" msg);
            Lwt_result.fail (Error.Migration_failed msg))
       : (unit, Error.t) Lwt_result.t))
  ;;

  let up db_label mig =
    let%lwt () = setup db_label in
    apply_up db_label mig
  ;;

  let down db_label mig =
    let%lwt () = setup db_label in
    let%lwt applied_ids = get_applied_ids db_label in
    let applied_set = applied_id_set applied_ids in
    let applied =
      CCList.filter (fun { Step.id; _ } -> is_applied applied_set id) mig.steps
    in
    let n = CCList.length applied in
    if n = 0
    then (
      Log.info (fun m ->
        m "No applied steps to revert for migration '%s'" (Namespace.show mig.namespace));
      Lwt_result.return ())
    else (
      let to_revert = CCList.rev applied in
      Log.info (fun m ->
        m "Reverting %d step(s) for migration '%s'" n (Namespace.show mig.namespace));
      (Lwt.catch
         (fun () ->
            let%lwt () = Lwt_list.iter_s (run_step_down db_label) to_revert in
            Lwt_result.return ())
         (fun exn ->
            let msg =
              Format.asprintf
                "Migration '%s' revert failed: %s"
                (Namespace.show mig.namespace)
                (Printexc.to_string exn)
            in
            Log.err (fun m -> m "%s" msg);
            Lwt_result.fail (Error.Migration_failed msg))
       : (unit, Error.t) Lwt_result.t))
  ;;

  let run_all db_label () =
    let%lwt () = setup db_label in
    let migs = migrations_for db_label in
    let rec run = function
      | [] -> Lwt_result.return ()
      | mig :: rest ->
        (match%lwt apply_up db_label mig with
         | Error e -> Lwt_result.fail e
         | Ok () -> run rest)
    in
    run migs
  ;;

  let status db_label () =
    let%lwt () = setup db_label in
    let%lwt applied_ids = get_applied_ids db_label in
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

  let pending db_label () =
    let%lwt statuses = status db_label () in
    Lwt.return
    @@ CCList.filter_map
         (fun (ns, applied, total) ->
            let n = total - applied in
            CCOption.return_if (n > 0) (ns, n))
         statuses
  ;;

  let check db_label () =
    let%lwt () = setup db_label in
    let sql = Db.Config.Dialect.select_applied_rows ~table:(Lazy.force table_name) in
    let req = Caqti_type.(unit ->* t2 string string) ~oneshot:true sql in
    let%lwt raw_rows = Db.collect db_label req () in
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

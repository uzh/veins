let src = Logs.Src.create "veins.connection"

module Log = (val Logs.src_log src : Logs.LOG)

let restore_autocommit =
  Dialect.request
    Caqti.Template.Request.Static
    Caqti.Templater.T.(unit -->. unit)
    (fun kind -> Dialect.restore_autocommit kind |> CCOption.get_or ~default:"")
;;

let insert_row table columns row_type =
  Caqti.Template.Request.create
    Caqti.Template.Request.Dynamic
    Caqti.Templater.T.(row_type -->. unit)
    (fun (_ : Caqti.Template.Dialect.t) ->
       let open Caqti.Template.Query in
       concat
         [ lit "INSERT INTO "
         ; lit table
         ; lit " ("
         ; concat ~sep:", " (CCList.map lit columns)
         ; lit ") VALUES ("
         ; concat ~sep:", " (CCList.mapi (fun i (_ : string) -> param i) columns)
         ; lit ")"
         ])
;;

module Fixed_mariadb (C : Caqti_lwt.CONNECTION) : Caqti_lwt.CONNECTION = struct
  include C

  let in_transaction = ref false

  let start () =
    match%lwt C.start () with
    | Ok () ->
      in_transaction := true;
      Lwt_result.return ()
    | Error _ as error -> Lwt.return error
  ;;

  (* the driver restores autocommit also when the commit fails *)
  let commit () =
    in_transaction := false;
    C.commit ()
  ;;

  let rollback () =
    in_transaction := false;
    let%lwt rolled_back = C.rollback () in
    let%lwt restored = C.exec restore_autocommit () in
    Lwt.return
      (match rolled_back with
       | Error _ as error -> error
       | Ok () -> restored)
  ;;

  let with_transaction f =
    match%lwt start () with
    | Error _ as error -> Lwt.return error
    | Ok () ->
      (match%lwt f () with
       | Ok result ->
         (match%lwt commit () with
          | Ok () -> Lwt_result.return result
          | Error _ as error ->
            let%lwt (_ : (unit, Caqti.Error.t) result) = rollback () in
            Lwt.return error)
       | Error _ as error ->
         let%lwt (_ : (unit, Caqti.Error.t) result) = rollback () in
         Lwt.return error
       | exception exn ->
         let%lwt (_ : (unit, Caqti.Error.t) result) = rollback () in
         Lwt.reraise exn)
  ;;

  let populate ~table ~columns row_type rows =
    let request = insert_row table columns row_type in
    let insert () =
      let%lwt inserted = Caqti_lwt.Stream.iter_s ~f:(C.exec request) rows in
      let%lwt (_ : (unit, Caqti.Error.t) result) = C.deallocate request in
      Lwt.return inserted
    in
    if !in_transaction then insert () else with_transaction insert
  ;;
end

let fixed ((module C : Caqti_lwt.CONNECTION) as connection) : Caqti_lwt.connection =
  match Dialect.kind C.dialect with
  | Dialect.Postgresql -> connection
  | Dialect.Mariadb -> (module Fixed_mariadb (C))
;;

let set_fk_checks enabled =
  Dialect.request
    Caqti.Template.Request.Direct
    Caqti.Templater.T.(unit -->. unit)
    (fun kind -> Dialect.set_fk_checks kind enabled |> CCOption.get_or ~default:"")
;;

let disable_fk_checks = set_fk_checks false
let enable_fk_checks = set_fk_checks true

let without_fk_checks (module C : Caqti_lwt.CONNECTION) f =
  match Dialect.set_fk_checks (Dialect.kind C.dialect) false with
  | None -> f ()
  | Some (_ : string) ->
    let enable () =
      match%lwt C.exec enable_fk_checks () with
      | Ok () -> Lwt.return_unit
      | Error error ->
        Lwt.return
          (Log.err (fun m ->
             m "Failed to turn foreign key checks back on: %a" Caqti.Error.pp error))
    in
    (match%lwt C.exec disable_fk_checks () with
     | Error _ as error -> Lwt.return error
     | Ok () ->
       (match%lwt f () with
        | Ok value ->
          (match%lwt C.exec enable_fk_checks () with
           | Ok () -> Lwt_result.return value
           | Error _ as error -> Lwt.return error)
        | Error _ as error ->
          let%lwt () = enable () in
          Lwt.return error
        | exception exn ->
          let%lwt () = enable () in
          Lwt.reraise exn))
;;

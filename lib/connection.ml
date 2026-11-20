let src = Logs.Src.create "veins.connection"

module Log = (val Logs.src_log src : Logs.LOG)

(* Direct and without parameters, the driver sends it as text: one round trip,
   where a prepared statement takes a second one to reset it. *)
let restore_autocommit =
  Dialect.request
    Caqti.Template.Request.Direct
    Caqti.Templater.T.(unit -->. unit)
    (fun kind -> Dialect.restore_autocommit kind |> CCOption.get_or ~default:"")
;;

(* Rows per INSERT of [populate]: a round trip per batch instead of per row.
   Small enough for rows of the usual size to stay below MariaDB's
   max_allowed_packet (16 MiB by default); never more placeholders than a
   prepared statement takes. *)
let populate_batch_rows = 100
let max_placeholders = 65_535

(* [count] rows of [row_type] as one parameter: their fields in a row. *)
type 'a rows =
  | Rows : 'b Caqti.Template.Row_type.t * ('a list -> ('b, string) result) -> 'a rows

let rec rows_rep row_type count =
  let wrong_size = Error "populate: a batch of the wrong size" in
  if count <= 1
  then
    Rows
      ( row_type
      , function
        | [ row ] -> Ok row
        | _ -> wrong_size )
  else (
    let (Rows (rest, encode_rest)) = rows_rep row_type (count - 1) in
    Rows
      ( Caqti.Template.Row_type.t2 row_type rest
      , function
        | row :: rows -> CCResult.map (fun rest -> row, rest) (encode_rest rows)
        | [] -> wrong_size ))
;;

let rows_type row_type count =
  let (Rows (rep, encode)) = rows_rep row_type count in
  Caqti.Template.Row_type.custom
    ~encode
    ~decode:(fun (_ : _) -> Error "populate: rows are only written")
    rep
;;

let insert_rows table columns row_type count =
  let width = Caqti.Template.Row_type.length row_type in
  Caqti.Template.Request.create
    Caqti.Template.Request.Dynamic
    Caqti.Templater.T.(rows_type row_type count -->. unit)
    (fun (_ : Caqti.Template.Dialect.t) ->
       let open Caqti.Template.Query in
       let row index =
         concat
           [ lit "("
           ; concat
               ~sep:", "
               (CCList.mapi (fun i (_ : string) -> param ((index * width) + i)) columns)
           ; lit ")"
           ]
       in
       concat
         [ lit "INSERT INTO "
         ; lit table
         ; lit " ("
         ; concat ~sep:", " (CCList.map lit columns)
         ; lit ") VALUES "
         ; concat ~sep:", " (CCList.init count row)
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

  let rollback () =
    in_transaction := false;
    let%lwt rolled_back = C.rollback () in
    let%lwt restored = C.exec restore_autocommit () in
    Lwt.return
      (match rolled_back with
       | Error _ as error -> error
       | Ok () -> restored)
  ;;

  (* Turning autocommit back on commits the open transaction: one round trip,
     where the driver's commit takes two (COMMIT, then autocommit). When it
     fails, roll back, which turns autocommit on in any case. *)
  let commit () =
    in_transaction := false;
    match%lwt C.exec restore_autocommit () with
    | Ok () -> Lwt_result.return ()
    | Error _ as error ->
      let%lwt (_ : (unit, Caqti.Error.t) result) = rollback () in
      Lwt.return error
  ;;

  let with_transaction f =
    match%lwt start () with
    | Error _ as error -> Lwt.return error
    | Ok () ->
      (match%lwt f () with
       | Ok result ->
         (match%lwt commit () with
          | Ok () -> Lwt_result.return result
          | Error _ as error -> Lwt.return error)
       | Error _ as error ->
         let%lwt (_ : (unit, Caqti.Error.t) result) = rollback () in
         Lwt.return error
       | exception exn ->
         let%lwt (_ : (unit, Caqti.Error.t) result) = rollback () in
         Lwt.reraise exn)
  ;;

  let populate ~table ~columns row_type rows =
    let size =
      let width = CCInt.max 1 (Caqti.Template.Row_type.length row_type) in
      CCInt.max 1 (CCInt.min populate_batch_rows (max_placeholders / width))
    in
    let full = insert_rows table columns row_type size in
    let insert () =
      let add row (count, batch) =
        let batch = row :: batch in
        if count + 1 < size
        then Lwt_result.return (count + 1, batch)
        else C.exec full (CCList.rev batch) |> Lwt_result.map (fun () -> 0, [])
      in
      let%lwt inserted =
        match%lwt Caqti_lwt.Stream.fold_s ~f:add rows (0, []) with
        | Ok (0, (_ : _ list)) -> Lwt_result.return ()
        | Ok (count, batch) ->
          let last = insert_rows table columns row_type count in
          let%lwt inserted = C.exec last (CCList.rev batch) in
          let%lwt (_ : (unit, Caqti.Error.t) result) = C.deallocate last in
          Lwt.return (inserted :> (unit, _) result)
        | Error _ as error -> Lwt.return error
      in
      let%lwt (_ : (unit, Caqti.Error.t) result) = C.deallocate full in
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

(* Caqti's messages show the URI with only its userinfo password masked:
   show it like [Url.pp] does, and mask any password still left. *)
let redacted url error =
  let shown = Format.asprintf "%a" Caqti.Error.pp_uri (Caqti.Error.uri error) in
  let message = Caqti.Error.show error in
  let message =
    if CCString.is_empty shown
    then message
    else CCString.replace ~sub:shown ~by:(Entity.Url.show url) message
  in
  let uri = Entity.Url.to_uri url in
  let in_query =
    Uri.query uri
    |> CCList.filter_map (fun (name, values) ->
      match CCString.lowercase_ascii name with
      | "password" | "sslpassword" ->
        Some
          (CCList.flat_map
             (fun value -> [ value; Uri.pct_encode ~component:`Query_value value ])
             values)
      | (_ : string) -> None)
    |> CCList.flatten
  in
  let in_userinfo =
    match Uri.password uri with
    | None -> []
    | Some password -> [ password; Uri.pct_encode ~component:`Userinfo password ]
  in
  CCList.fold_left
    (fun message password ->
       if CCString.is_empty password
       then message
       else CCString.replace ~sub:password ~by:"***" message)
    message
    (in_userinfo @ in_query)
;;

let test ?(post_connect = fun (_ : Caqti_lwt.connection) -> Lwt_result.return ()) url =
  match%lwt
    Caqti_lwt_unix.with_connection (Entity.Url.to_connect_uri url) (fun connection ->
      post_connect (fixed connection))
  with
  | Ok () -> Lwt_result.return ()
  | Error error -> Lwt_result.fail (Error.Connection_failed (redacted url error))
;;

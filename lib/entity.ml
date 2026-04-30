module Label = struct
  type t = string

  let create s = s
  let value s = s
  let equal = CCString.equal
  let compare = CCString.compare
  let hash = Hashtbl.hash
  let pp = Format.pp_print_string
  let show s = s
end

module Role = struct
  type t = string

  let create s = s
  let value s = s
  let equal = CCString.equal
  let pp = Format.pp_print_string
  let show s = s
end

module Url = struct
  type t = string

  let create s = s
  let to_uri = Uri.of_string

  let redact s =
    let u = Uri.of_string s in
    match Uri.password u with
    | None | Some "" -> s
    | Some _ -> Uri.with_password u (Some "***") |> Uri.to_string
  ;;

  let equal = CCString.equal
  let pp fmt s = Format.pp_print_string fmt (redact s)
  let show = redact
end

module Status = struct
  type t =
    | Active
    | ConnectionIssue
    | Disabled
    | Maintenance
    | MigrationsConnectionIssue
    | MigrationsFailed
    | MigrationsPending

  let all =
    [ Active
    ; ConnectionIssue
    ; Disabled
    ; Maintenance
    ; MigrationsConnectionIssue
    ; MigrationsFailed
    ; MigrationsPending
    ]
  ;;

  let show = function
    | Active -> "active"
    | ConnectionIssue -> "connection_issue"
    | Disabled -> "disabled"
    | Maintenance -> "maintenance"
    | MigrationsConnectionIssue -> "migrations_connection_issue"
    | MigrationsFailed -> "migrations_failed"
    | MigrationsPending -> "migrations_pending"
  ;;

  let equal (a : t) (b : t) = Stdlib.(a = b)

  let of_string = function
    | "active" -> Ok Active
    | "connection_issue" -> Ok ConnectionIssue
    | "disabled" -> Ok Disabled
    | "maintenance" -> Ok Maintenance
    | "migrations_connection_issue" -> Ok MigrationsConnectionIssue
    | "migrations_failed" -> Ok MigrationsFailed
    | "migrations_pending" -> Ok MigrationsPending
    | s -> Error ("Unknown database status: " ^ s)
  ;;

  let pp fmt t = Format.pp_print_string fmt (show t)
end

module Database = struct
  type pool =
    | Main of Url.t
    | Multiple of (Role.t * Url.t) list

  type t =
    { label : Label.t
    ; status : Status.t
    ; pool : pool
    }

  let create ?(status = Status.Active) label pool =
    (match pool with
     | Main _ -> ()
     | Multiple roles ->
       let seen = Hashtbl.create (CCList.length roles) in
       CCList.iter
         (fun (role, _) ->
            if Hashtbl.mem seen role
            then
              invalid_arg
                (Format.asprintf "Database.create: duplicate role %a" Role.pp role);
            Hashtbl.add seen role ())
         roles);
    { label; status; pool }
  ;;

  let label { label; _ } = label
  let status { status; _ } = status
  let pool { pool; _ } = pool

  let url ?role { pool; _ } =
    match pool, role with
    | Main db_url, None -> db_url
    | Main db_url, Some _ ->
      Logs.warn (fun m ->
        m "Database.url: role provided for Main pool; ignoring and returning primary URL");
      db_url
    | Multiple _, None -> invalid_arg "Database.url: role is required for Multiple pool"
    | Multiple databases, Some role ->
      CCList.assoc_opt ~eq:Role.equal role databases
      |> CCOption.get_exn_or
           (Format.asprintf "Database.url: unknown role %a" Role.pp role)
  ;;
end

module Dynparam = struct
  type t = Pack : 'a Caqti_type.t * 'a -> t

  let empty = Pack (Caqti_type.unit, ())
  let add t x (Pack (t', x')) = Pack (Caqti_type.t2 t' t, (x', x))
  let prefix t x (Pack (t', x')) = Pack (Caqti_type.t2 t t', (x, x'))
end

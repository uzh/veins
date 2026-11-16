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

module Login = struct
  type t = string

  let owner_name = "owner"
  let owner = owner_name

  let create name =
    if CCString.equal name owner_name
    then invalid_arg "Login.create: \"owner\" is the database's own URL, use Login.owner";
    name
  ;;

  let name t = t
  let is_owner = CCString.equal owner_name
  let equal = CCString.equal
  let compare = CCString.compare
  let hash = Hashtbl.hash
  let pp = Format.pp_print_string
  let show t = t
end

module Need = struct
  type +'g t = string list

  let v name = [ name ]
  let none = []
  let ( & ) a b = CCList.sort_uniq ~cmp:CCString.compare (a @ b)
  let names t = t

  let pp fmt t =
    match t with
    | [] -> Format.pp_print_string fmt "nothing"
    | names ->
      Format.pp_print_list
        ~pp_sep:(fun fmt () -> Format.pp_print_string fmt ", ")
        Format.pp_print_string
        fmt
        names
  ;;
end

module Role = struct
  type 'g t =
    { name : string
    ; login : Login.t
    }

  let v ?(login = Login.owner) name = { name; login }
  let owner = { name = "owner"; login = Login.owner }
  let name { name; _ } = name
  let login { login; _ } = login
  let pp fmt { name; _ } = Format.pp_print_string fmt name
  let show { name; _ } = name
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
  type t =
    { label : Label.t
    ; status : Status.t
    ; owner : Url.t
    ; logins : (Login.t * Url.t) list
    }

  let create ?(status = Status.Active) ?(logins = []) label owner =
    let seen = Hashtbl.create (CCList.length logins) in
    CCList.iter
      (fun (login, _) ->
         if Login.is_owner login
         then invalid_arg "Database.create: the owner login is the database's own URL";
         if Hashtbl.mem seen login
         then
           invalid_arg
             (Format.asprintf "Database.create: duplicate login %a" Login.pp login);
         Hashtbl.add seen login ())
      logins;
    { label; status; owner; logins }
  ;;

  let label { label; _ } = label
  let status { status; _ } = status
  let owner { owner; _ } = owner
  let with_status status database = { database with status }
  let logins { logins; _ } = CCList.map fst logins
  let has_login { logins; _ } login = CCList.mem_assoc ~eq:Login.equal login logins

  let url { owner; logins; _ } login =
    CCList.assoc_opt ~eq:Login.equal login logins |> CCOption.value ~default:owner
  ;;
end

module Dynparam = struct
  type t = Pack : 'a Caqti_type.t * 'a -> t

  let empty = Pack (Caqti_type.unit, ())
  let add t x (Pack (t', x')) = Pack (Caqti_type.t2 t' t, (x', x))
  let prefix t x (Pack (t', x')) = Pack (Caqti_type.t2 t t', (x, x'))
end

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

module Capability = struct
  type t =
    { id : int
    ; name : string
    }

  let registry : (string, unit) Hashtbl.t = Hashtbl.create 16
  let next_id = ref 0

  let create name =
    if Hashtbl.mem registry name
    then
      invalid_arg
        (Format.asprintf "Capability.create: a capability named %S already exists" name);
    Hashtbl.add registry name ();
    incr next_id;
    { id = !next_id; name }
  ;;

  let name { name; _ } = name
  let equal a b = Int.equal a.id b.id
  let compare a b = Int.compare a.id b.id
  let pp fmt { name; _ } = Format.pp_print_string fmt name
  let show { name; _ } = name

  module Set = struct
    include Set.Make (struct
        type nonrec t = t

        let compare = compare
      end)

    let pp fmt set =
      Format.fprintf
        fmt
        "{%a}"
        (Format.pp_print_list ~pp_sep:(fun fmt () -> Format.pp_print_string fmt ", ") pp)
        (elements set)
    ;;
  end
end

module Role = struct
  type t =
    { name : string
    ; capabilities : Capability.Set.t
    }

  let create ?(capabilities = []) name =
    { name; capabilities = Capability.Set.of_list capabilities }
  ;;

  let value { name; _ } = name
  let capabilities { capabilities; _ } = capabilities
  let equal a b = CCString.equal a.name b.name
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
  type pool =
    | Main of Url.t
    | Multiple of (Role.t * Url.t) list

  type role_policy =
    | Fallback
    | Strict

  type t =
    { label : Label.t
    ; status : Status.t
    ; pool : pool
    ; role_policy : role_policy
    }

  let create ?(status = Status.Active) ?(role_policy = Fallback) label pool =
    (match pool with
     | Main _ -> ()
     | Multiple [] -> invalid_arg "Database.create: Multiple needs at least one role"
     | Multiple roles ->
       let seen = Hashtbl.create (CCList.length roles) in
       CCList.iter
         (fun (role, _) ->
            let name = Role.value role in
            if Hashtbl.mem seen name
            then
              invalid_arg
                (Format.asprintf "Database.create: duplicate role %a" Role.pp role);
            Hashtbl.add seen name ())
         roles);
    { label; status; pool; role_policy }
  ;;

  let label { label; _ } = label
  let status { status; _ } = status
  let pool { pool; _ } = pool
  let role_policy { role_policy; _ } = role_policy

  let roles { pool; _ } =
    match pool with
    | Main _ -> []
    | Multiple roles -> CCList.map fst roles
  ;;

  let find_role t role = CCList.find_opt (Role.equal role) (roles t)

  let url ?role { pool; role_policy; _ } =
    match pool, role with
    | Main db_url, None -> db_url
    | Main db_url, Some _ when role_policy = Fallback -> db_url
    | Main _, Some role ->
      invalid_arg
        (Format.asprintf
           "Database.url: role %a requested on a single-URL database with the Strict \
            policy"
           Role.pp
           role)
    | Multiple _, None -> invalid_arg "Database.url: role is required for Multiple pool"
    | Multiple databases, Some role ->
      CCList.find_map
        (fun (r, url) -> if Role.equal role r then Some url else None)
        databases
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

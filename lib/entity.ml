module Label = struct
  type t = string

  let create s = s
  let value s = s
  let equal = String.equal
  let compare = String.compare
  let hash = Hashtbl.hash
  let pp = Format.pp_print_string
  let show s = s
end

module Url = struct
  type t = string

  let create s = s
  let to_uri = Uri.of_string

  let redact s =
    let u = Uri.of_string s in
    (match Uri.password u with
     | None | Some "" -> u
     | Some _ -> Uri.with_password u (Some "***"))
    |> Uri.to_string
  ;;

  let equal = String.equal
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

  let equal a b = String.equal (show a) (show b)

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
    ; url : Url.t
    ; status : Status.t
    }

  let create ?(status = Status.Active) label url = { label; url; status }
  let label { label; _ } = label
  let url { url; _ } = url
  let status { status; _ } = status
end

module Dynparam = struct
  type t = Pack : 'a Caqti_type.t * 'a -> t

  let empty = Pack (Caqti_type.unit, ())
  let add t x (Pack (t', x')) = Pack (Caqti_type.t2 t' t, (x', x))
  let prefix t x (Pack (t', x')) = Pack (Caqti_type.t2 t t', (x, x'))
end

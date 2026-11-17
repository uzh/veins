type dialects =
  | Both
  | Only of Veins.Dialect.kind

let dialects_of_string = function
  | "both" -> Some Both
  | "mariadb" -> Some (Only Veins.Dialect.Mariadb)
  | "postgresql" -> Some (Only Veins.Dialect.Postgresql)
  | _ -> None
;;

let uuid_v4 rng = Uuidm.(v4_gen rng () |> to_string)
let random_ids rng ~steps = CCList.init steps (fun _ -> uuid_v4 rng)

let iso8601 p =
  let (y, m, d), ((hh, mm, ss), _) = Ptime.to_date_time p in
  Format.asprintf "%04d-%02d-%02dT%02d:%02d:%02dZ" y m d hh mm ss
;;

let compact_timestamp p =
  let (y, m, d), ((hh, mm, ss), _) = Ptime.to_date_time p in
  Format.asprintf "%04d%02d%02d%02d%02d%02d" y m d hh mm ss
;;

let slugify s =
  let sanitized =
    CCString.map
      (fun c ->
         match c with
         | 'a' .. 'z' | '0' .. '9' -> c
         | 'A' .. 'Z' -> Char.lowercase_ascii c
         | _ -> ' ')
      s
  in
  CCString.split_on_char ' ' sanitized
  |> CCList.filter (fun s -> not (CCString.is_empty s))
  |> CCString.concat "_"
;;

let module_name_of_slug slug =
  let base =
    CCString.split_on_char '_' slug
    |> CCList.filter (fun s -> not (CCString.is_empty s))
    |> CCList.map CCString.capitalize_ascii
    |> CCString.concat ""
  in
  let base = if CCString.is_empty base then "Migration" else base in
  match CCString.get base 0 with
  | '0' .. '9' -> "Migration" ^ base
  | _ -> base
;;

let indent n text =
  let pad = CCString.make n ' ' in
  CCString.split_on_char '\n' text
  |> CCList.map (fun line -> if CCString.is_empty line then line else pad ^ line)
  |> CCString.concat "\n"
;;

let sql_literal todo = Printf.sprintf "{sql|TODO: %s|sql}" todo

let sql_block ~dialects todo =
  let literal = sql_literal todo in
  match dialects with
  | Both ->
    Printf.sprintf
      "Migration.Sql.v\n  ~mariadb:%s\n  ~postgresql:%s\n  ()"
      literal
      literal
  | Only kind ->
    let kind =
      match kind with
      | Veins.Dialect.Mariadb -> "Mariadb"
      | Veins.Dialect.Postgresql -> "Postgresql"
    in
    Printf.sprintf "Migration.Sql.only Dialect.%s %s" kind literal
;;

let binding name sql =
  if CCString.contains sql '\n'
  then Printf.sprintf "  let %s =\n%s\n  in" name (indent 4 sql)
  else Printf.sprintf "  let %s = %s in" name sql
;;

let step ~dialects ~index ~id =
  Printf.sprintf
    {|let step_%d =
%s
%s
  Migration.Step.create
    ~id:(Migration.Id.create %S)
    ~label:"TODO: describe step %d"
    ~down
    up
;;
|}
    index
    (binding "up" (sql_block ~dialects "forward SQL"))
    (binding "down" (sql_block ~dialects "reverse SQL"))
    id
    index
;;

let fill_comment ~width sentences =
  let words = CCString.split_on_char ' ' (CCString.concat " " sentences) in
  let lines, last =
    CCList.fold_left
      (fun (lines, line) word ->
         if CCString.length line + 1 + CCString.length word > width
         then line :: lines, "   " ^ word
         else lines, line ^ " " ^ word)
      ([], "(*")
      words
  in
  CCString.concat "\n" (CCList.rev ((last ^ " *)") :: lines))
;;

let header_comment dialects =
  let leave_out =
    match dialects with
    | Both ->
      [ "Leave out the SQL of a dialect the application never runs on, in [up] and \
         [down] alike."
      ]
    | Only _ -> []
  in
  fill_comment
    ~width:80
    ([ "Steps run in the order [migration] adds them. Once a step is deployed, never \
        change its id or [up], or remove it: append a new step instead."
     ]
     @ leave_out
     @ [ "The runner refuses to apply a step whose [up] SQL is still a TODO, and to \
          revert a migration while a [down] is: write it, or drop [~down] if the step \
          can't be reverted."
       ])
;;

let migration_binding ~namespace ~written_at ~steps =
  let create = "Migration.create namespace ~written_at" in
  let body =
    match steps with
    | 1 -> Printf.sprintf "  %s |> Migration.add_step step_1" create
    | n ->
      CCList.init n (fun i -> Printf.sprintf "  |> Migration.add_step step_%d" (i + 1))
      |> CCString.concat "\n"
      |> Printf.sprintf "  %s\n%s" create
  in
  Printf.sprintf
    {|let migration =
  let namespace = Migration.Namespace.create %S in
  let written_at = Migration.ptime_of_string %S in
%s
;;
|}
    namespace
    (iso8601 written_at)
    body
;;

let render ~module_name ~namespace ~written_at ~dialects ~ids =
  if CCList.is_empty ids then invalid_arg "Veins_gen_template.render: no step ids";
  let steps =
    CCList.mapi (fun i id -> step ~dialects ~index:(i + 1) ~id) ids
    |> CCString.concat "\n"
  in
  Printf.sprintf
    {|(** Migration: %s *)

open Veins

%s

%s
%s
let () = Migration.register migration
|}
    module_name
    (header_comment dialects)
    steps
    (migration_binding ~namespace ~written_at ~steps:(CCList.length ids))
;;

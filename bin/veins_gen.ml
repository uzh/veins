let uuid_v4 rng = Uuidm.(v4_gen rng () |> to_string)

let iso8601_now p =
  let (y, m, d), ((hh, mm, ss), _) = Ptime.to_date_time p in
  Format.asprintf "%04d-%02d-%02dT%02d:%02d:%02dZ" y m d hh mm ss
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

let step_template ~index ~id =
  Printf.sprintf
    {|let step_%d =
  let up =
    Sql.v
      ~mariadb:
        {sql|
          TODO: forward SQL
        |sql}
      ~postgresql:
        {sql|
          TODO: forward SQL
        |sql}
      ()
  in
  let down =
    Sql.v
      ~mariadb:
        {sql|
          TODO: reverse SQL
        |sql}
      ~postgresql:
        {sql|
          TODO: reverse SQL
        |sql}
      ()
  in
  Step.create
    ~id:(Id.create %S)
    ~label:"TODO: describe step %d"
    ~down
    up
;;
|}
    index
    id
    index
;;

let template ~module_name ~namespace ~written_at =
  let rng = Random.State.make_self_init () in
  let indices = [ 1; 2 ] in
  let steps =
    CCList.map (fun index -> step_template ~index ~id:(uuid_v4 rng)) indices
    |> CCString.concat "\n"
  in
  let add_steps =
    CCList.map (Printf.sprintf "  |> add_step step_%d") indices |> CCString.concat "\n"
  in
  Printf.sprintf
    {|(** Migration: %s *)

open Veins
open Migration

(* Steps run in the order [migration] adds them. Once a step is deployed, never
   change or remove it: append a new step instead. *)

%s
let migration =
  let namespace = Namespace.create %S in
  let written_at = ptime_of_string %S in
  create namespace ~written_at
%s
;;

let () = register migration
|}
    module_name
    steps
    namespace
    written_at
    add_steps
;;

let compact_timestamp p =
  let (y, m, d), ((hh, mm, ss), _) = Ptime.to_date_time p in
  Format.asprintf "%04d%02d%02d%02d%02d%02d" y m d hh mm ss
;;

let die msg =
  prerr_endline msg;
  exit 1
;;

let usage () = die "Usage: veins-gen <migration description>"

let module_name_of_slug slug =
  let cap s = CCString.capitalize_ascii s in
  let base =
    CCString.split_on_char '_' slug
    |> CCList.filter (fun s -> not (CCString.is_empty s))
    |> CCList.map cap
    |> CCString.concat ""
  in
  let base = if CCString.is_empty base then "Migration" else base in
  match CCString.get base 0 with
  | '0' .. '9' -> "Migration" ^ base
  | _ -> base
;;

let ensure_dir path =
  if not (Sys.file_exists path && Sys.is_directory path)
  then die (Format.asprintf "Invalid migration directory: %s" path)
;;

let () =
  let now = Ptime_clock.now () in
  let args =
    match Array.to_list Sys.argv with
    | _ :: args -> args
    | [] -> assert false
  in
  let s = CCString.trim (CCString.concat " " args) in
  if CCString.is_empty s then usage ();
  let slug = slugify s in
  if CCString.is_empty slug
  then die "Migration description must contain at least one alphanumeric character.";
  let compact = compact_timestamp now in
  let written_at = iso8601_now now in
  let output_dir =
    match Sys.getenv_opt "VEINS_MIGRATION_DIR" with
    | Some d when not (CCString.is_empty d) -> d
    | _ -> "."
  in
  ensure_dir output_dir;
  let filename =
    Filename.concat output_dir (Format.asprintf "migration_%s_%s.ml" compact slug)
  in
  if Sys.file_exists filename
  then die (Format.asprintf "File already exists: %s" filename);
  let module_name = module_name_of_slug slug in
  let content = template ~module_name ~namespace:slug ~written_at in
  (match open_out_bin filename with
   | exception Sys_error msg -> die (Format.asprintf "Cannot create %s: %s" filename msg)
   | oc ->
     (match
        Fun.protect
          ~finally:(fun () -> close_out_noerr oc)
          (fun () ->
             output_string oc content;
             close_out oc)
      with
      | exception Sys_error msg ->
        die (Format.asprintf "Cannot write %s: %s" filename msg)
      | () -> ()));
  print_endline ("Generated: " ^ filename)
;;

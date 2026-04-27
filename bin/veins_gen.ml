let uuid_v4 () =
  let rng = Random.State.make_self_init () in
  Uuidm.(v4_gen rng () |> to_string)
;;

let iso8601_now p =
  let (y, m, d), ((hh, mm, ss), _) = Ptime.to_date_time p in
  Format.asprintf "%04d-%02d-%02dT%02d:%02d:%02dZ" y m d hh mm ss
;;

let slugify s =
  let sanitized =
    String.map
      (fun c ->
         match c with
         | 'a' .. 'z' | '0' .. '9' -> c
         | 'A' .. 'Z' -> Char.chr (Char.code c + 32)
         | _ -> ' ')
      s
  in
  String.split_on_char ' ' sanitized
  |> List.filter (fun s -> s <> "")
  |> String.concat "_"
;;

let template ~module_name ~namespace ~written_at =
  let uuid1 = uuid_v4 () in
  let uuid2 = uuid_v4 () in
  Format.asprintf
    {|(** Migration: %s *)

open Veins

let migration =
  Migration.(
    create
      (Namespace.create %S)
      ~written_at:(ptime_of_string %S)
    |> add_step
         (Step.create
            ~id:(Id.create %S)
            ~label:"TODO: describe step 1"
            ~down:"TODO: reverse SQL"
            "TODO: forward SQL")
    |> add_step
         (Step.create
            ~id:(Id.create %S)
            ~label:"TODO: describe step 2"
            ~down:"TODO: reverse SQL"
            "TODO: forward SQL")
  )

let () = Migration.register migration
|}
    module_name
    namespace
    written_at
    uuid1
    uuid2
;;

let compact_timestamp p =
  let (y, m, d), ((hh, mm, ss), _) = Ptime.to_date_time p in
  Format.asprintf "%04d%02d%02d%02d%02d%02d" y m d hh mm ss
;;

let () =
  let now = Ptime_clock.now () in
  let args =
    match Array.to_list Sys.argv with
    | _ :: args -> args
    | [] ->
      prerr_endline "Usage: veins-gen <migration description>";
      exit 1
  in
  let s = String.trim (String.concat " " args) in
  if s = ""
  then (
    prerr_endline "Usage: veins-gen <migration description>";
    exit 1);
  let slug = slugify s in
  if slug = ""
  then (
    prerr_endline
      "Migration description must contain at least one alphanumeric character.";
    exit 1);
  let compact = compact_timestamp now in
  let written_at = iso8601_now now in
  let output_dir =
    match Sys.getenv_opt "VEINS_MIGRATION_DIR" with
    | Some d when String.length d > 0 -> d
    | _ -> "."
  in
  let filename =
    Filename.concat output_dir (Format.asprintf "migration_%s_%s.ml" compact slug)
  in
  if Sys.file_exists filename
  then (
    Printf.eprintf "File already exists: %s\n" filename;
    exit 1);
  let module_name =
    let cap s =
      if String.length s = 0
      then s
      else
        String.make 1 (Char.uppercase_ascii s.[0]) ^ String.sub s 1 (String.length s - 1)
    in
    String.concat "" (List.map cap (String.split_on_char '_' slug))
  in
  let content = template ~module_name ~namespace:slug ~written_at in
  let oc = open_out filename in
  Printf.fprintf oc "%s" content;
  close_out oc;
  Printf.printf "Generated: %s\n" filename
;;

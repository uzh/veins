let die msg =
  prerr_endline msg;
  exit 1
;;

let usage_text =
  "Usage: veins-gen [--steps N] [--dialect both|mariadb|postgresql] [--] <migration \
   description>\n\n\
   Options are read only before the description; use -- before a description that starts \
   with -."
;;

let usage () = die usage_text

let help () =
  print_endline usage_text;
  exit 0
;;

type options =
  { steps : int
  ; dialects : Veins_gen_template.dialects
  ; words : string list
  }

let rec parse options = function
  | "--steps" :: n :: rest ->
    (match CCInt.of_string n with
     | Some steps when steps >= 1 -> parse { options with steps } rest
     | _ -> die (Format.asprintf "--steps needs a positive number, got %S" n))
  | "--dialect" :: d :: rest ->
    (match Veins_gen_template.dialects_of_string d with
     | Some dialects -> parse { options with dialects } rest
     | None -> die (Format.asprintf "--dialect is both, mariadb or postgresql, got %S" d))
  | ("--steps" | "--dialect") :: [] -> usage ()
  | ("-h" | "--help") :: _ -> help ()
  | "--" :: words -> { options with words }
  | option :: _ when CCString.prefix ~pre:"-" option ->
    die (Format.asprintf "Unknown option %S\n%s" option usage_text)
  | words -> { options with words }
;;

let ensure_dir path =
  if not (Sys.file_exists path && Sys.is_directory path)
  then die (Format.asprintf "Invalid migration directory: %s" path)
;;

let () =
  let open Veins_gen_template in
  let now = Ptime_clock.now () in
  let args =
    match Array.to_list Sys.argv with
    | _ :: args -> args
    | [] -> assert false
  in
  let { steps; dialects; words } =
    parse { steps = 1; dialects = Both; words = [] } args
  in
  let s = CCString.trim (CCString.concat " " words) in
  if CCString.is_empty s then usage ();
  let slug = slugify s in
  if CCString.is_empty slug
  then die "Migration description must contain at least one alphanumeric character.";
  let output_dir =
    match Sys.getenv_opt "VEINS_MIGRATION_DIR" with
    | Some d when not (CCString.is_empty d) -> d
    | _ -> "."
  in
  ensure_dir output_dir;
  let filename =
    Filename.concat
      output_dir
      (Format.asprintf "migration_%s_%s.ml" (compact_timestamp now) slug)
  in
  if Sys.file_exists filename
  then die (Format.asprintf "File already exists: %s" filename);
  let content =
    render
      ~module_name:(module_name_of_slug slug)
      ~namespace:slug
      ~written_at:now
      ~dialects
      ~ids:(random_ids (Random.State.make_self_init ()) ~steps)
  in
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

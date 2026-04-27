open Unix

let iso8601_now () =
  let tm = Unix.gmtime (Unix.gettimeofday ()) in
  Printf.sprintf
    "%04d-%02d-%02dT%02d:%02d:%02dZ"
    (tm.tm_year + 1900)
    (tm.tm_mon + 1)
    tm.tm_mday
    tm.tm_hour
    tm.tm_min
    tm.tm_sec
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

let template ~module_name ~namespace ~written_at ~uuid1 ~uuid2 =
  Printf.sprintf
    {|(** Migration: %s *)

open Veins

let migration =
  Migration.(
    empty
      (Namespace.create %S)
      ~written_at:(ptime_of_string %S)
    |> add_step
         (step
            ~id:(Id.create %S)
            ~label:"TODO: describe step 1"
            ~down:"TODO: reverse SQL"
            "TODO: forward SQL")
    |> add_step
         (step
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

let uuid_v4 () =
  let hex n =
    let s = Bytes.create n in
    for i = 0 to n - 1 do
      let v = Random.int 16 in
      Bytes.set s i (if v < 10 then Char.chr (v + 48) else Char.chr (v + 87))
    done;
    Bytes.to_string s
  in
  Printf.sprintf
    "%s-%s-4%s-%x%s-%s"
    (hex 8)
    (hex 4)
    (hex 3)
    (Random.int 4 + 8)
    (hex 3)
    (hex 12)
;;

let compact_timestamp () =
  let tm = Unix.gmtime (Unix.gettimeofday ()) in
  Printf.sprintf
    "%04d%02d%02d%02d%02d%02d"
    (tm.tm_year + 1900)
    (tm.tm_mon + 1)
    tm.tm_mday
    tm.tm_hour
    tm.tm_min
    tm.tm_sec
;;

let () =
  Random.self_init ();
  let args = Sys.argv |> Array.to_list |> List.tl in
  let s = String.concat " " args in
  let slug = slugify s in
  let compact = compact_timestamp () in
  let written_at = iso8601_now () in
  let filename = Printf.sprintf "migration_%s_%s.ml" compact slug in
  let module_name =
    let cap s =
      if String.length s = 0
      then s
      else
        String.make 1 (Char.uppercase_ascii s.[0]) ^ String.sub s 1 (String.length s - 1)
    in
    String.concat "" (List.map cap (String.split_on_char '_' slug))
  in
  let namespace = slug in
  let uuid1 = uuid_v4 () in
  let uuid2 = uuid_v4 () in
  let content = template ~module_name ~namespace ~written_at ~uuid1 ~uuid2 in
  if Sys.file_exists filename
  then (
    Printf.eprintf "File already exists: %s\n" filename;
    exit 1);
  let oc = open_out filename in
  Printf.fprintf oc "%s" content;
  close_out oc;
  Printf.printf "Generated: %s\n" filename
;;

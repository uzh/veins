(* Prints a generated migration with fixed ids and timestamp:
   [gen_fixture.exe DIALECTS STEPS NAMESPACE]. *)

let () =
  match Sys.argv with
  | [| _; dialects; steps; namespace |] ->
    let dialects = Option.get (Veins_gen_template.dialects_of_string dialects) in
    let ids =
      List.init (int_of_string steps) (fun i ->
        Printf.sprintf "00000000-0000-4000-8000-%012d" (i + 1))
    in
    print_string
      (Veins_gen_template.render
         ~module_name:(Veins_gen_template.module_name_of_slug namespace)
         ~namespace
         ~written_at:(Veins.Migration.ptime_of_string "2026-04-24T14:03:14Z")
         ~dialects
         ~ids)
  | _ -> failwith "usage: gen_fixture.exe DIALECTS STEPS NAMESPACE"
;;

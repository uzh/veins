module LabelHash = struct
  type t = Entity.Label.t

  let equal = Entity.Label.equal
  let hash = Entity.Label.hash
end

module Tbl = CCHashtbl.Make (LabelHash)

let store : Entity.Database.t Tbl.t = Tbl.create 8

let register db = Tbl.replace store (Entity.Database.label db) db
;;

let find label = Tbl.find_opt store label
;;

let find_exn label =
  match Tbl.find_opt store label with
  | Some db -> db
  | None ->
    raise Not_found
;;

let all () = Tbl.values_list store
;;

let remove  = Tbl.remove store
;;

let clear () = Tbl.clear store
;;

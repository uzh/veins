(* Needs and roles shared by every test suite. Each role connects as its own
   login; the suites give the logins URLs when the per-role database users
   exist (the *_READER_URL etc. variables), the owner's URL otherwise. *)

let read : [> `Read ] Veins.Need.t = Veins.Need.v "read"
let write : [> `Write ] Veins.Need.t = Veins.Need.v "write"
let schema : [> `Schema ] Veins.Need.t = Veins.Need.v "schema"
let reader_login = Veins.Login.create "reader"
let writer_login = Veins.Login.create "writer"
let migrator_login = Veins.Login.create "migrator"
let reader : [ `Read ] Veins.Role.t = Veins.Role.v ~login:reader_login "reader"
let writer : [ `Read | `Write ] Veins.Role.t = Veins.Role.v ~login:writer_login "writer"

let migrator : [ `Read | `Write | `Schema ] Veins.Role.t =
  Veins.Role.v ~login:migrator_login "migrator"
;;

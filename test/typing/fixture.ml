(* Roles, needs and statements the cases in cases/ misuse. Compiled by
   check.sh, not by dune. *)

open Caqti_request.Infix

module Db = Veins.Pools.Make (struct
    let database =
      Veins.Database.create (Veins.Label.create "x") (Veins.Url.create "mariadb://x/y")
    ;;

    let database_pool_size = 1
    let expected_databases = 1

    module Dialect = Veins.Dialect.Mariadb
  end)

let read : [> `Read ] Veins.Need.t = Veins.Need.v "read"
let write : [> `Write ] Veins.Need.t = Veins.Need.v "write"
let query : [ `Read ] Veins.Role.t = Veins.Role.v "query"
let command : [ `Read | `Write ] Veins.Role.t = Veins.Role.v "command"
let label = Veins.Label.create "x"

let find =
  (Caqti_type.int ->? Caqti_type.string) "SELECT name FROM t WHERE id = ?"
  |> Veins.Request.create ~needs:read
;;

let insert =
  (Caqti_type.int ->. Caqti_type.unit) "INSERT INTO t (id) VALUES (?)"
  |> Veins.Request.create ~needs:Veins.Need.(read & write)
;;

(* A repository function: its type says it needs [`Read | `Write]. *)
let save ctx id = Lwt.bind (Db.find_opt ctx find id) (fun _ -> Db.exec ctx insert id)

(* These must compile: a top-level request runs on every role granting its
   needs, the owner runs everything. *)
let (_ : string option Lwt.t) = Db.find_opt (Db.label_ctx ~role:query label) find 1
let (_ : string option Lwt.t) = Db.find_opt (Db.label_ctx ~role:command label) find 1
let (_ : unit Lwt.t) = save (Db.label_ctx ~role:command label) 1
let (_ : unit Lwt.t) = save (Db.label_ctx ~role:Veins.Role.owner label) 1

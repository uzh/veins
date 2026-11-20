(* Roles, needs and statements the cases in cases/ misuse. Compiled by
   check.sh, not by dune. *)

module T = Caqti.Templater.T

module Db = Veins.Pools.Make (struct
    let database () =
      Veins.Database.create (Veins.Label.create "x") (Veins.Url.create "mariadb://x/y")
    ;;

    let database_pool_size = 1
    let expected_databases = 1

    module Driver = Veins.Driver.Generic
  end)

let read : [> `Read ] Veins.Need.t = Veins.Need.v "read"
let write : [> `Write ] Veins.Need.t = Veins.Need.v "write"
let query : [ `Read ] Veins.Role.t = Veins.Role.v "query"
let command : [ `Read | `Write ] Veins.Role.t = Veins.Role.v "command"
let label = Veins.Label.create "x"

let find =
  Caqti.Templater.static T.(int -->? string) "SELECT name FROM t WHERE id = ?"
  |> Veins.Request.create ~needs:read
;;

let insert =
  Caqti.Templater.static T.(int -->. unit) "INSERT INTO t (id) VALUES (?)"
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

(* Without roles: plain Caqti requests on contexts that name no role, and
   statements with needs through [with_roles]. *)
module Plain = Veins.Plain.Make (Db)

let plain_find =
  Caqti.Templater.static T.(int -->? string) "SELECT name FROM t WHERE id = ?"
;;

let (_ : string option Lwt.t) = Plain.find_opt (Plain.label_ctx label) plain_find 1

let (_ : unit Lwt.t) =
  Plain.transaction_ctx label (fun ctx -> save (Veins.Plain.Ctx.with_roles ctx) 1)
;;

(* Typed migration sets: [register] takes only the tags of [S.t]. *)
module Sets =
  Veins.Migration.Sets.Make
    (struct
      type t =
        [ `Root
        | `Tenant
        ]

      let all = [ `Root; `Tenant ]

      let name = function
        | `Root -> "root"
        | `Tenant -> "tenant"
      ;;

      let out_of_order (_ : t) = `Fail
    end)
    (Db)

let migration =
  Veins.Migration.create
    (Veins.Migration.Namespace.create "m")
    ~written_at:(Veins.Migration.ptime_of_string "2024-01-01T00:00:00Z")
;;

let () = Sets.register ~sets:[ `Root; `Tenant ] migration

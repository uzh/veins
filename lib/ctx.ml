module After_commit = struct
  type t = (unit -> unit) list ref

  let create () : t = ref []
  let add (t : t) f = t := f :: !t

  let run ~on_error (t : t) =
    CCList.rev !t
    |> CCList.iter (fun hook ->
      try hook () with
      | exn -> on_error exn)
  ;;
end

type no_transaction = [ `no_transaction ]
type transaction = [ `transaction ]

type (!_, 'g) t =
  | Label :
      { label : Entity.Label.t
      ; role : 'g Entity.Role.t
      ; tags : Logs.Tag.set
      }
      -> (no_transaction, 'g) t
  | Connection :
      { connection : Caqti_lwt.connection
      ; label : Entity.Label.t
      ; role : 'g Entity.Role.t
      ; tags : Logs.Tag.set
      ; mutex : Lwt_mutex.t
      }
      -> (no_transaction, 'g) t
  | Transaction :
      { connection : Caqti_lwt.connection
      ; label : Entity.Label.t
      ; role : 'g Entity.Role.t
      ; tags : Logs.Tag.set
      ; mutex : Lwt_mutex.t
      ; on_commit : After_commit.t
      }
      -> (transaction, 'g) t

type _ txn =
  | Yes : transaction txn
  | No : no_transaction txn

type 'g any = Any : ('maybe_txn, 'g) t -> 'g any [@@ocaml.unboxed]

let txn (type maybe_txn g) : (maybe_txn, g) t -> maybe_txn txn = function
  | Label _ -> No
  | Connection _ -> No
  | Transaction _ -> Yes
;;

let is_transaction (type maybe_txn g) (ctx : (maybe_txn, g) t) =
  match txn ctx with
  | Yes -> true
  | No -> false
;;

let label (type maybe_txn g) : (maybe_txn, g) t -> Entity.Label.t = function
  | Label { label; _ } | Connection { label; _ } | Transaction { label; _ } -> label
;;

let role (type maybe_txn g) : (maybe_txn, g) t -> g Entity.Role.t = function
  | Label { role; _ } | Connection { role; _ } | Transaction { role; _ } -> role
;;

let tags (type maybe_txn g) : (maybe_txn, g) t -> Logs.Tag.set = function
  | Label { tags; _ } | Connection { tags; _ } | Transaction { tags; _ } -> tags
;;

let mutex (type maybe_txn g) : (maybe_txn, g) t -> Lwt_mutex.t option = function
  | Label _ -> None
  | Connection { mutex; _ } | Transaction { mutex; _ } -> Some mutex
;;

let connection (type maybe_txn g) : (maybe_txn, g) t -> Caqti_lwt.connection option
  = function
  | Label _ -> None
  | Connection { connection; _ } | Transaction { connection; _ } -> Some connection
;;

let after_commit (type maybe_txn g) (ctx : (maybe_txn, g) t) f =
  match ctx with
  | Transaction { on_commit; _ } -> After_commit.add on_commit f
  | Label _ | Connection _ -> f ()
;;

let on_commit (type g) (Transaction { on_commit; _ } : (transaction, g) t) = on_commit

let label_tag : Entity.Label.t Logs.Tag.def =
  Logs.Tag.def "database_label" ~doc:"Database label" Entity.Label.pp
;;

let make_tags label tags =
  CCOption.value ~default:Logs.Tag.empty tags |> Logs.Tag.add label_tag label
;;

let label_ctx ?tags ~role label = Label { label; role; tags = make_tags label tags }

let connection_ctx ?tags ~role label connection =
  Connection
    { connection; label; role; tags = make_tags label tags; mutex = Lwt_mutex.create () }
;;

let transaction_ctx ?tags ~role ?(mutex = Lwt_mutex.create ()) label connection =
  Transaction
    { connection
    ; label
    ; role
    ; tags = make_tags label tags
    ; mutex
    ; on_commit = After_commit.create ()
    }
;;

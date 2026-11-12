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

type !_ t =
  | Label :
      { label : Entity.Label.t
      ; role : Entity.Role.t option
      ; tags : Logs.Tag.set
      }
      -> no_transaction t
  | Connection :
      { connection : Caqti_lwt.connection
      ; label : Entity.Label.t
      ; role : Entity.Role.t option
      ; tags : Logs.Tag.set
      ; mutex : Lwt_mutex.t
      ; capabilities : Entity.Capability.Set.t option
      }
      -> no_transaction t
  | Transaction :
      { connection : Caqti_lwt.connection
      ; label : Entity.Label.t
      ; role : Entity.Role.t option
      ; tags : Logs.Tag.set
      ; mutex : Lwt_mutex.t
      ; capabilities : Entity.Capability.Set.t option
      ; on_commit : After_commit.t
      }
      -> transaction t

type _ txn =
  | Yes : transaction txn
  | No : no_transaction txn

type any = Any : 'maybe_txn t -> any [@@ocaml.unboxed]

let txn (type maybe_txn) : maybe_txn t -> maybe_txn txn = function
  | Label _ -> No
  | Connection _ -> No
  | Transaction _ -> Yes
;;

let is_transaction (type maybe_txn) (ctx : maybe_txn t) =
  match txn ctx with
  | Yes -> true
  | No -> false
;;

let label (type maybe_txn) : maybe_txn t -> Entity.Label.t = function
  | Label { label; _ } | Connection { label; _ } | Transaction { label; _ } -> label
;;

let role (type maybe_txn) : maybe_txn t -> Entity.Role.t option = function
  | Label { role; _ } | Connection { role; _ } | Transaction { role; _ } -> role
;;

let tags (type maybe_txn) : maybe_txn t -> Logs.Tag.set = function
  | Label { tags; _ } | Connection { tags; _ } | Transaction { tags; _ } -> tags
;;

let mutex (type maybe_txn) : maybe_txn t -> Lwt_mutex.t option = function
  | Label _ -> None
  | Connection { mutex; _ } | Transaction { mutex; _ } -> Some mutex
;;

let connection (type maybe_txn) : maybe_txn t -> Caqti_lwt.connection option = function
  | Label _ -> None
  | Connection { connection; _ } | Transaction { connection; _ } -> Some connection
;;

let held_capabilities (type maybe_txn)
  : maybe_txn t -> Entity.Capability.Set.t option option
  = function
  | Label _ -> None
  | Connection { capabilities; _ } | Transaction { capabilities; _ } -> Some capabilities
;;

let after_commit (type maybe_txn) (ctx : maybe_txn t) f =
  match ctx with
  | Transaction { on_commit; _ } -> After_commit.add on_commit f
  | Label _ | Connection _ -> f ()
;;

let on_commit (Transaction { on_commit; _ } : transaction t) = on_commit

let label_tag : Entity.Label.t Logs.Tag.def =
  Logs.Tag.def "database_label" ~doc:"Database label" Entity.Label.pp
;;

let make_tags label tags =
  CCOption.value ~default:Logs.Tag.empty tags |> Logs.Tag.add label_tag label
;;

let label_ctx ?tags ?role label = Label { label; role; tags = make_tags label tags }

let connection_ctx ?tags ?role ~capabilities label connection =
  Connection
    { connection
    ; label
    ; role
    ; tags = make_tags label tags
    ; mutex = Lwt_mutex.create ()
    ; capabilities
    }
;;

let transaction_ctx
      ?tags
      ?role
      ?(mutex = Lwt_mutex.create ())
      ~capabilities
      label
      connection
  =
  Transaction
    { connection
    ; label
    ; role
    ; tags = make_tags label tags
    ; mutex
    ; capabilities
    ; on_commit = After_commit.create ()
    }
;;

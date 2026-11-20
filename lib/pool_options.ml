type failure =
  { label : Entity.Label.t
  ; role : string option
  ; request : string option
  ; params : string option
  ; exn : exn
  ; connection_error : bool
  }

type t =
  { max_use_count : int option
  ; max_idle_size : int option
  ; max_idle_age : float option
  ; statement_timeout : float option
  ; acquire_timeout : float option
  ; reconnect_backoff : float * float
  ; on_failure : (failure -> unit Lwt.t) option
  }

let default =
  { max_use_count = None
  ; max_idle_size = None
  ; max_idle_age = Some 300.
  ; statement_timeout = None
  ; acquire_timeout = None
  ; reconnect_backoff = 0.5, 30.
  ; on_failure = None
  }
;;

let validate t =
  let fail field = invalid_arg (Format.asprintf "Pool_options: invalid %s" field) in
  let positive field = function
    | Some seconds when not (seconds > 0.) -> fail field
    | Some _ | None -> ()
  in
  let at_least field minimum = function
    | Some n when n < minimum -> fail field
    | Some _ | None -> ()
  in
  at_least "max_use_count" 1 t.max_use_count;
  at_least "max_idle_size" 0 t.max_idle_size;
  positive "max_idle_age" t.max_idle_age;
  positive "statement_timeout" t.statement_timeout;
  positive "acquire_timeout" t.acquire_timeout;
  let initial, max = t.reconnect_backoff in
  if not (initial >= 0. && max >= initial) then fail "reconnect_backoff";
  t
;;

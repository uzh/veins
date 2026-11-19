(* Network doubles for the resilience tests. *)

let close_quietly fd =
  Lwt.catch (fun () -> Lwt_unix.close fd) (fun (_ : exn) -> Lwt.return_unit)
;;

let listen () =
  let socket = Lwt_unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Lwt_unix.setsockopt socket Unix.SO_REUSEADDR true;
  let%lwt () = Lwt_unix.bind socket (Unix.ADDR_INET (Unix.inet_addr_loopback, 0)) in
  Lwt_unix.listen socket 32;
  let port =
    match Lwt_unix.getsockname socket with
    | Unix.ADDR_INET (_, port) -> port
    | Unix.ADDR_UNIX _ -> failwith "expected an inet socket"
  in
  Lwt.return (socket, port)
;;

(* Closing the listening socket ends the loop with EBADF; that is how it stops. *)
let accept_loop socket handle =
  Lwt.async (fun () ->
    let rec loop () =
      let%lwt client, _ = Lwt_unix.accept socket in
      Lwt.async (fun () -> handle client);
      loop ()
    in
    Lwt.catch loop (fun (_ : exn) -> Lwt.return_unit))
;;

(** A server that accepts connections and closes them again after a short,
    staggered delay, like a database that just went away. Counts the
    connections it accepted, so a test can prove nothing was sent. *)
module Unresponsive = struct
  type t =
    { socket : Lwt_unix.file_descr
    ; port : int
    ; mutable accepted : int
    }

  let start () =
    let%lwt socket, port = listen () in
    let t = { socket; port; accepted = 0 } in
    accept_loop socket (fun client ->
      let delay = 0.5 +. (0.2 *. float_of_int t.accepted) in
      t.accepted <- t.accepted + 1;
      let%lwt () = Lwt_unix.sleep delay in
      close_quietly client);
    Lwt.return t
  ;;

  let url t ~scheme = Format.asprintf "%s://root@127.0.0.1:%d/test" scheme t.port
  let stop t = close_quietly t.socket
end

(** A TCP proxy in front of a real database. [set_down t true] cuts every
    open connection and closes new ones right away, like an outage;
    [set_down t false] forwards again.

    It runs on system threads with blocking I/O, not on Lwt: caqti-driver-
    postgresql connects with libpq's blocking PQconnectdb, which holds up the
    Lwt loop until the handshake is done, so a proxy on that loop would never
    answer it. *)
module Proxy = struct
  type t =
    { socket : Unix.file_descr
    ; port : int
    ; target : Unix.sockaddr
    ; lock : Mutex.t
    ; mutable down : bool
    ; mutable open_fds : Unix.file_descr list
    }

  let locked t f =
    Mutex.lock t.lock;
    CCFun.protect ~finally:(fun () -> Mutex.unlock t.lock) f
  ;;

  let quietly f fd =
    try f fd with
    | (_ : exn) -> ()
  ;;

  (* Wakes a thread blocked on [fd]; only the thread owning [fd] closes it. *)
  let cut = quietly (fun fd -> Unix.shutdown fd Unix.SHUTDOWN_ALL)
  let close = quietly Unix.close

  (* Copies until either side ends, then cuts both so the other pump ends too. *)
  let pump ~src ~dst =
    let buffer = Bytes.create 16384 in
    let rec write offset length =
      if length > 0
      then (
        let n = Unix.write dst buffer offset length in
        write (offset + n) (length - n))
    in
    let rec loop () =
      match Unix.read src buffer 0 (Bytes.length buffer) with
      | 0 -> ()
      | n ->
        write 0 n;
        loop ()
    in
    (try loop () with
     | (_ : exn) -> ());
    cut src;
    cut dst
  ;;

  let forward t client =
    let upstream = Unix.socket (Unix.domain_of_sockaddr t.target) Unix.SOCK_STREAM 0 in
    match Unix.connect upstream t.target with
    | exception (_ : exn) ->
      close upstream;
      close client
    | () ->
      let accepted =
        locked t (fun () ->
          if not t.down then t.open_fds <- client :: upstream :: t.open_fds;
          not t.down)
      in
      if accepted
      then (
        let pumps =
          [ Thread.create (fun () -> pump ~src:client ~dst:upstream) ()
          ; Thread.create (fun () -> pump ~src:upstream ~dst:client) ()
          ]
        in
        CCList.iter Thread.join pumps;
        locked t (fun () ->
          t.open_fds
          <- CCList.filter (fun fd -> fd != client && fd != upstream) t.open_fds));
      close client;
      close upstream
  ;;

  (* Ends when [stop] shuts the listening socket down. *)
  let accept_loop t =
    let rec loop () =
      match Unix.accept ~cloexec:true t.socket with
      | exception (_ : exn) -> close t.socket
      | client, _ ->
        if locked t (fun () -> t.down)
        then close client
        else ignore (Thread.create (forward t) client : Thread.t);
        loop ()
    in
    loop ()
  ;;

  (** [start uri] proxies to the host and port of [uri]; returns [uri]
      pointing at the proxy. *)
  let start ~default_port uri =
    (* a write to a connection the other side closed must not end the process *)
    Sys.set_signal Sys.sigpipe Sys.Signal_ignore;
    let host = Uri.host uri |> CCOption.get_exn_or "database URL without host" in
    let port = Uri.port uri |> CCOption.value ~default:default_port in
    let target =
      match
        Unix.getaddrinfo host (string_of_int port) [ Unix.AI_SOCKTYPE Unix.SOCK_STREAM ]
      with
      | { Unix.ai_addr; _ } :: _ -> ai_addr
      | [] -> failwith ("cannot resolve " ^ host)
    in
    let socket = Unix.socket ~cloexec:true Unix.PF_INET Unix.SOCK_STREAM 0 in
    Unix.setsockopt socket Unix.SO_REUSEADDR true;
    Unix.bind socket (Unix.ADDR_INET (Unix.inet_addr_loopback, 0));
    Unix.listen socket 32;
    let port =
      match Unix.getsockname socket with
      | Unix.ADDR_INET (_, port) -> port
      | Unix.ADDR_UNIX _ -> failwith "expected an inet socket"
    in
    let t =
      { socket; port; target; lock = Mutex.create (); down = false; open_fds = [] }
    in
    ignore (Thread.create accept_loop t : Thread.t);
    let proxied = Uri.with_port (Uri.with_host uri (Some "127.0.0.1")) (Some port) in
    Lwt.return (t, proxied)
  ;;

  let set_down t down =
    let fds =
      locked t (fun () ->
        t.down <- down;
        if down then t.open_fds else [])
    in
    CCList.iter cut fds;
    Lwt.return_unit
  ;;

  let stop t =
    let%lwt () = set_down t true in
    cut t.socket;
    Lwt.return_unit
  ;;
end

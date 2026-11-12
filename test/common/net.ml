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
    [set_down t false] forwards again. *)
module Proxy = struct
  type t =
    { socket : Lwt_unix.file_descr
    ; port : int
    ; target : Unix.sockaddr
    ; mutable down : bool
    ; mutable open_fds : Lwt_unix.file_descr list
    }

  let pump ~src ~dst =
    let buffer = Bytes.create 16384 in
    let rec write offset length =
      if length = 0
      then Lwt.return_unit
      else (
        let%lwt n = Lwt_unix.write dst buffer offset length in
        write (offset + n) (length - n))
    in
    let rec loop () =
      match%lwt Lwt_unix.read src buffer 0 (Bytes.length buffer) with
      | 0 -> Lwt.return_unit
      | n ->
        let%lwt () = write 0 n in
        loop ()
    in
    Lwt.catch loop (fun (_ : exn) -> Lwt.return_unit)
  ;;

  let forward t client =
    if t.down
    then close_quietly client
    else (
      let upstream =
        Lwt_unix.socket (Unix.domain_of_sockaddr t.target) Unix.SOCK_STREAM 0
      in
      match%lwt Lwt_unix.connect upstream t.target with
      | exception (_ : exn) ->
        let%lwt () = close_quietly upstream in
        close_quietly client
      | () ->
        t.open_fds <- client :: upstream :: t.open_fds;
        let%lwt () =
          Lwt.pick [ pump ~src:client ~dst:upstream; pump ~src:upstream ~dst:client ]
        in
        let%lwt () = close_quietly client in
        close_quietly upstream)
  ;;

  (** [start uri] proxies to the host and port of [uri]; returns [uri]
      pointing at the proxy. *)
  let start ~default_port uri =
    let host = Uri.host uri |> CCOption.get_exn_or "database URL without host" in
    let port = Uri.port uri |> CCOption.value ~default:default_port in
    let%lwt addresses =
      Lwt_unix.getaddrinfo host (string_of_int port) [ Unix.AI_SOCKTYPE Unix.SOCK_STREAM ]
    in
    let target =
      match addresses with
      | { Unix.ai_addr; _ } :: _ -> ai_addr
      | [] -> failwith ("cannot resolve " ^ host)
    in
    let%lwt socket, proxy_port = listen () in
    let t = { socket; port = proxy_port; target; down = false; open_fds = [] } in
    accept_loop socket (forward t);
    let proxied =
      Uri.with_port (Uri.with_host uri (Some "127.0.0.1")) (Some proxy_port)
    in
    Lwt.return (t, proxied)
  ;;

  let set_down t down =
    t.down <- down;
    if down
    then (
      let fds = t.open_fds in
      t.open_fds <- [];
      Lwt_list.iter_p close_quietly fds)
    else Lwt.return_unit
  ;;

  let stop t =
    let%lwt () = set_down t true in
    close_quietly t.socket
  ;;
end

(** A global, in-process registry of named {!Entity.Database.t} entries.

    Use this module to declare all database configurations at startup so that
    pool functors and other components can look them up by label without
    threading configuration through the call stack.

    {[
      (* Register databases once at startup *)
      let () =
        let url = Entity.Url.create (Sys.getenv "DATABASE_URL") in
        Databases.register (Entity.Database.create (Entity.Label.create "root") url)

      (* Retrieve later by label *)
      let db = Databases.find_exn (Entity.Label.create "root")
    ]}
*)

(** Register [db] in the global cache, keyed by [Entity.Database.label db].
    Silently replaces any existing entry with the same label. *)
val register : Entity.Database.t -> unit

(** [find label] returns [Some db] for the registered entry whose label equals
    [label], or [None] if no such entry exists. *)
val find : Entity.Label.t -> Entity.Database.t option

(** Like {!find} but raises [Not_found] if the label is not registered. *)
val find_exn : Entity.Label.t -> Entity.Database.t

(** Return all currently registered databases in unspecified order. *)
val all : unit -> Entity.Database.t list

(** Remove the entry for [label] from the cache.  No-op if not present. *)
val remove : Entity.Label.t -> unit

(** Clear all entries from the cache. *)
val clear : unit -> unit

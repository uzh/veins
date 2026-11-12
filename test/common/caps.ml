(* Capabilities shared by every test suite; created once per process. *)

let read = Veins.Capability.create "test_read"
let write = Veins.Capability.create "test_write"
let schema = Veins.Capability.create "test_schema"
let reader = Veins.Role.create "reader" ~capabilities:[ read ]
let writer = Veins.Role.create "writer" ~capabilities:[ read; write ]
let migrator = Veins.Role.create "migrator" ~capabilities:[ read; write; schema ]

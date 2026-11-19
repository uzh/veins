# veins

Database connection pooling and schema migration library for OCaml.

- **Connection pools** — label-based multi-database pool management backed by [Caqti](https://github.com/paurkedal/ocaml-caqti) and Lwt
- **Migrations** — ordered, versioned, up/down migration steps with a global registry and drift detection
- **MariaDB and PostgreSQL** — veins' SQL follows each connection's dialect; use the driver library you need
  (`veins.mariadb` or `veins.postgresql`)
- **Roles or a single user** — statements checked against typed roles at compile time, or `Plain` pools without
  roles for applications with one database user
- **`veins-gen`** — CLI tool to generate migration file boilerplate

---

## Installation

```zsh
opam install veins caqti-driver-mariadb      # for MariaDB / MySQL
opam install veins caqti-driver-postgresql   # for PostgreSQL
```

There is one opam package, `veins`. Its driver libraries are installed when their Caqti driver is, so name both in
your opam file and the library in dune:

```
depends: [ "veins" "caqti-driver-mariadb" ]
```

```dune
(libraries veins veins.mariadb)
```

See [Package and libraries](#package-and-libraries).

---

## Quick start

### 1. Define a pool

```ocaml
open Veins

(* The URL is typically read from an environment variable. *)
let db () = Database.create (Label.create "root") (Url.create (Sys.getenv "DATABASE_URL"))

module Db = Veins_mariadb.Pools.Make (struct
  let database = db
  (* database_pool_size defaults to 10, expected_databases to 5 *)
end)

let () = Db.Pool.initialize ()
```

`database` is a function: `Pool.initialize` calls it, not the module's creation, so it may read a configuration that
is loaded at startup (an `.env` file, a test setup).

For custom pool sizes, or when you need to wire up the driver yourself:

```ocaml
module Db = Veins.Pools.Make (struct
  module Driver       = Veins_mariadb.Driver
  let database        = db
  let database_pool_size = 25
  let expected_databases = 1
end)
```

### 2. Declare roles and what statements need

A role is a part of your application with a type: the rights it has, as polymorphic variant tags you choose. A
statement's needs are a lower bound of those tags. Declare each once, with its type:

```ocaml
let read : [> `Read ] Need.t = Need.v "read"
let write : [> `Write ] Need.t = Need.v "write"

let query : [ `Read ] Role.t = Role.v "query"
let command : [ `Read | `Write ] Role.t = Role.v "command"

let find_user =
  {sql| SELECT name FROM users WHERE id = ? |sql}
  |> Caqti.Templater.(static T.(int -->? string))
  |> Request.create ~needs:read

let create_user =
  {sql| INSERT INTO users (name) VALUES (?) |sql}
  |> Caqti.Templater.(static T.(string -->. unit))
  |> Request.create ~needs:Need.(read & write)
```

`Need.none` declares no needs (e.g. `SELECT 1`, or code that hasn't declared them yet). `Role.owner` runs every
statement.

### 3. Run them on a context

A context says where statements run and as which role: `label_ctx` takes a fresh connection per statement,
`connection_ctx` holds one connection, `transaction_ctx` holds one connection inside a transaction.

```ocaml
let root = Label.create "root"

let%lwt name = Db.find_opt (Db.label_ctx ~role:query root) find_user 42

let%lwt () =
  Db.transaction_ctx ~role:command root (fun ctx ->
    Ctx.after_commit ctx (fun () -> Logs.info (fun m -> m "user created"));
    Db.exec ctx create_user "alice")
```

`Db.with_transaction ctx f` joins `ctx` when it is a transaction already, so functions can ask for a transaction
without knowing whether their caller opened one. Hooks registered with `Ctx.after_commit` run after the commit and
are dropped on rollback.

Errors the database reports raise `Error.Failed` with the label, login, role and untouched Caqti error; match on
`Error.cause_of_exn exn` (e.g. `` `Unique_violation ``) instead of on messages. Only errors that mean the connection
is gone drop and reconnect the pool.

### 4. Roles are checked by the compiler

A context carries its role's type, so a statement the role doesn't grant doesn't compile, and functions state the
rights they need in their signature:

```ocaml
let rename ctx name = Db.exec ctx create_user name
(* val rename : (_, [> `Read | `Write ]) Ctx.t -> string -> unit Lwt.t *)

rename (Db.label_ctx ~role:query root) "bob"
(* Error: ... The first variant type does not allow tag(s) `Write *)
```

This holds for nested transactions (`with_transaction` keeps the role) and for `query`, `populate` and
`transaction`, which take `~needs`. Nothing is checked at runtime.

Functions that get the Caqti connection itself (`query`, `transaction`) get a `Veins.Connection.fixed` one: on
MariaDB its `rollback`, `with_transaction` and `populate` work around caqti-driver-mariadb 3.1 (autocommit left off
after a rollback; `populate` not rolling back a failing row and committing the transaction it is called in), so
the whole `Caqti_lwt.CONNECTION` interface is safe to use. Only connections taken from `Pool.fetch`'s Caqti pool
are the driver's own; pass those through `Veins.Connection.fixed`.

`populate` inserts all rows or none, and joins the transaction of a transaction context. Its table and column
names go into the SQL as they are, like the fragments of `Veins.Dialect`: never build them from user input.

A label context checks its connection before every statement (on MariaDB a ping, i.e. one more round trip); code
running several statements is faster on one `connection_ctx` or transaction. Don't share a held context between
concurrent threads that use transactions: only statements are serialised, so one thread's statement would join
the transaction another has open.

### 5. Logins: one database user per role, or one for all

Each role connects as a `Login`, the database's own URL (`Login.owner`) unless it names another. A database has the
owner's URL and, optionally, a URL per login; a login without one connects with the owner's URL, on the owner's
pool:

```ocaml
let query_login = Login.create "query"
let command_login = Login.create "command"
let query : [ `Read ] Role.t = Role.v ~login:query_login "query"
let command : [ `Read | `Write ] Role.t = Role.v ~login:command_login "command"

(* one user for everything: the types separate the roles *)
let single = Database.create (Label.create "app") owner_url

(* one user per login: the database enforces each login's grants, too *)
let separated =
  Database.create (Label.create "app") owner_url
    ~strict_logins:true
    ~logins:[ query_login, Url.create query_url; command_login, Url.create command_url ]
```

A login without a URL runs with the owner's rights; veins logs that once per login. For a database meant to
separate its users, pass `~strict_logins:true`: a role whose login has no URL (a misspelt login, a URL missing
from the configuration) then fails with `Error.Login_not_configured` instead of quietly running as the owner.

Several roles may share a login; the database then enforces only what the login is granted, and the types the rest.
A role claiming more than its login is granted passes the compiler, but the database refuses the statement:
`Error.Permission_denied` (MariaDB errors 1044, 1142, 1143, 1227, 1370; PostgreSQL SQLSTATE 42501, recognised by
the driver libraries) names the label, login, role and declared needs.

### 6. Without roles: one database user for everything

An application that connects with a single user and doesn't separate rights takes the `Plain` pools: contexts
have no role, statements are plain Caqti requests, and nothing takes `~role` or `~needs`.

```ocaml
module Db = Veins_mariadb.Plain.Make (struct
  let database = db
end)

let find_user =
  {sql| SELECT name FROM users WHERE id = ? |sql}
  |> Caqti.Templater.(static T.(int -->? string))

let%lwt name = Db.find_opt (Db.label_ctx root) find_user 42

let%lwt () =
  Db.transaction_ctx root (fun ctx ->
    Plain.Ctx.after_commit ctx (fun () -> Logs.info (fun m -> m "user created"));
    Db.exec ctx create_user "alice")

let rename ctx name = Db.exec ctx create_user name
(* val rename : _ Plain.Ctx.t -> string -> unit Lwt.t *)
```

These are the same pools underneath (`Db.With_roles`), every context being one of `Role.owner`: reconnects,
transactions, errors and `Pool` behave as above. Two bridges to code written with roles:

- `Veins.Migration.Make (Db.With_roles)` is the migration runner (leave its `?role` out).
- `Plain.Ctx.with_roles ctx` is the same context for functions that state their needs, e.g. those of a library:
  the single user grants whatever is asked for, and the statements join `ctx`'s transaction.

For another pool size or `Pool_options`, use `Veins_mariadb.Plain.Make_with_options` (or the PostgreSQL one), whose
configuration adds `database_pool_size`; over pools of your own, `Veins.Plain.Make (Veins.Pools.Make_with_options
(Config) (Options))`.

## Migrations

### Generating a migration file

```zsh
veins-gen "add users table"
# → migration_20260424140314_add_users_table.ml
```

Set `VEINS_MIGRATION_DIR` to write the file to a specific directory (defaults to the current directory):

```zsh
VEINS_MIGRATION_DIR=lib/migrations veins-gen "add users table"
# → lib/migrations/migration_20260424140314_add_users_table.ml
```

`--steps N` writes `N` steps (default 1), each with a fresh id. `--dialect mariadb` or `--dialect postgresql` writes
SQL placeholders for that dialect only (`Sql.only`), the default `both` writes one for each (`Sql.v`). Options are
read only before the description, so `veins-gen "fix --steps bug"` is a description; put `--` before a description
that starts with `-`.

The generated file defines each step on its own, then adds them to the migration and registers it (the files in
[`test/gen`](test/gen) are complete examples, compiled and linked by the tests):

```ocaml
open Veins

let step_1 =
  let up =
    Migration.Sql.v
      ~mariadb:{sql|TODO: forward SQL|sql}
      ~postgresql:{sql|TODO: forward SQL|sql}
      ()
  in
  let down = (* the same, with TODO: reverse SQL *) in
  Migration.Step.create
    ~id:(Migration.Id.create "30d5a1e5-81eb-4de6-b81e-6f0695ab3421")
    ~label:"TODO: describe step 1"
    ~down
    up
;;

let migration =
  let namespace = Migration.Namespace.create "add_users_table" in
  let written_at = Migration.ptime_of_string "2026-04-24T14:03:14Z" in
  Migration.create namespace ~written_at |> Migration.add_step step_1
;;

let () = Migration.register migration
```

Rename the steps after what they do, fill in the SQL, then link the file into your application. Every statement
names the dialects it is written for: `Sql.v ~mariadb ~postgresql ()` for one statement each (leave one out if the
application never runs on it), `Sql.only kind sql` for a single dialect, `Sql.any sql` for SQL that runs
anywhere. Before a run applies anything, the runner checks that every pending step has SQL for the connection's
dialect (`Runner.verify`), so a MariaDB-only migration fails up front on PostgreSQL instead of half way. SQL that
starts with `TODO:`, the generator's placeholder (`Sql.is_placeholder`), fails that check like missing SQL. `down`
likewise refuses to revert anything while an applied step's `down` is one: write it, or drop `~down`.

`~id` may be left out: the step then gets `Id.derive` of the namespace and its position, which is stable as long as
steps are only ever appended. Every file that calls `Migration.register` contributes its steps to the global
registry — no explicit list to maintain.

### Applying migrations

```ocaml
module Runner = Migration.Make (Db)

let root = Label.create "root"

(* Apply all pending migrations in chronological order. *)
let () = Lwt_main.run
  (match%lwt Runner.run_all root () with
   | Ok () -> Lwt.return_unit
   | Error e -> failwith (Error.show e))
```

Each runner call holds one connection, as the database owner unless you pass another role, e.g.
`Runner.run_all ~role:migrator root ()`; migration statements declare no needs, the login's grants limit them.

`run_all`, `up`, `down` and `mark_applied` hold a lock on the database while they run (MariaDB `GET_LOCK`,
PostgreSQL advisory lock), so instances starting together apply each step once; the others wait, at most
`VEINS_MIGRATION_LOCK_TIMEOUT` seconds (default 600). `status`, `pending` and `check` only read: no lock, no DDL,
so a read-only role can call them. The state table is `veins_migration_state`, or the plain table name in
`VEINS_MIGRATION_TABLE`.

### Drift detection

```ocaml
(* Returns a list of drift values — Pending (steps not yet applied),
   Orphaned (applied IDs no longer present in the registry) or Unsupported
   (pending steps without SQL for the connection's dialect). *)
let%lwt drifts = Runner.check (Label.create "root") () in
List.iter (function
  | Migration.Pending { namespace; pending_steps; _ } ->
    Printf.eprintf "pending: %s (%d steps)\n" (Migration.Namespace.show namespace) pending_steps
  | Migration.Orphaned { namespace; step_ids } ->
    Printf.eprintf "orphaned in %s: %d step(s)\n"
      (Migration.Namespace.show namespace) (List.length step_ids)
  | Migration.Unsupported { namespace; steps; _ } ->
    Printf.eprintf "no SQL for this dialect in %s: %s\n"
      (Migration.Namespace.show namespace) (String.concat ", " steps))
  drifts
```

### Coming from a counter-based engine

`Migration.Counter_state.Make (Db)` imports a table like Sihl's `core_migration_state` (one row per namespace:
steps applied, dirty flag): `import` marks the counted steps as applied (their ids derived from the positions, so
leave `~id` out), refuses dirty namespaces, and `record` keeps the counter up to date for a rollback to the previous
engine. It is deprecated from the start: drop it once every database ran the import.

---

## Package and libraries

One opam package, `veins`, with three libraries:

| Library (dune)     | Module             | Needs                     | Purpose                                                              |
|--------------------|--------------------|---------------------------|----------------------------------------------------------------------|
| `veins`            | `Veins`            |                           | Pools, migrations, the SQL of both dialects (`Veins.Dialect`)        |
| `veins.mariadb`    | `Veins_mariadb`    | `caqti-driver-mariadb`    | `Driver`, and `Pools.Make` / `Plain.Make` with it pre-configured     |
| `veins.postgresql` | `Veins_postgresql` | `caqti-driver-postgresql` | `Driver`, and `Pools.Make` / `Plain.Make` with it pre-configured     |

The Caqti drivers are optional dependencies (`depopts`) of `veins`: a driver library is built and installed only
when its driver is in the switch, so nobody needs `libpq` for a MariaDB application. opam has no way to ask for a
part of a package, so an application names the driver itself, next to `veins`. Installing a driver later makes
opam rebuild `veins` with its library.

The driver libraries only exist to read their driver's errors: Caqti classifies constraint violations, but not a
lost connection or a missing privilege, which veins needs to reconnect pools and to raise
`Error.Permission_denied`. The SQL veins sends doesn't depend on them: Caqti 3 renders each request for the dialect
of the connection it runs on (`Veins.Dialect.request`).

caqti-driver-postgresql connects blocking (libpq's `PQconnectdb`): the whole process waits until the server
answers, by default indefinitely. Veins adds `connect_timeout=5` (seconds) to PostgreSQL URLs that don't set it;
put `?connect_timeout=N` in the URL to choose another limit.

The `veins-gen` executable is installed as part of the `veins` package.

---

## Pool tuning and lost databases

`Pools.Make` (and the driver libraries' `Pools.Make`) use `Pool_options.default`. The driver libraries'
`Pools.Make_with_options` and `Plain.Make_with_options` take your own, and the pool size:

```ocaml
module Db =
  Veins_mariadb.Pools.Make_with_options
    (struct
      let database () = Database.create (Label.create "root") url
      let database_pool_size = 20
    end)
    (struct
      let options = Veins.Pool_options.{ default with statement_timeout = Some 30. }
    end)
```

`Veins.Pools.Make_with_options` is the same with every field of the configuration:

```ocaml
module Db =
  Veins.Pools.Make_with_options
    (struct
      let database () = Database.create (Label.create "root") url
      let database_pool_size = 10
      let expected_databases = 5

      module Driver = Veins_mariadb.Driver
    end)
    (struct
      let options =
        Veins.Pool_options.{ default with statement_timeout = Some 30.; acquire_timeout = Some 10. }
    end)
```

| Option              | Default       | Meaning                                                                             |
|---------------------|---------------|-------------------------------------------------------------------------------------|
| `max_use_count`     | `None`        | Close a connection after this many uses (Caqti's own default is 100)                |
| `max_idle_size`     | pool size     | Connections kept open while idle                                                    |
| `max_idle_age`      | `Some 300.`   | Seconds after which an idle connection is closed                                    |
| `statement_timeout` | `None`        | Seconds after which the database aborts a statement; migrations run without it      |
| `acquire_timeout`   | `None`        | Seconds a statement waits for a connection of an exhausted pool before it fails     |
| `reconnect_backoff` | `(0.5, 30.)`  | Initial and longest wait before a pool that lost its database tries to reconnect    |
| `on_failure`        | `None`        | Called with every error a statement raises, before it is raised                     |

**Reporting failures.** `on_failure` gets the label, the context's role, the request and its parameters (as Caqti
prints them, for `exec`, `collect`, `find` and `find_opt`) and the exception the statement raises right after
(`Error.Failed` or `Error.Exn`), e.g. to send it to an error tracker instead of wrapping every helper. Each error is
reported once, where veins raises it, not again when it leaves `connection_ctx` or `transaction_ctx`; `Pool.ping`
and the other `Pool` functions don't report. The statement waits for it, and an exception of it is logged and
dropped.

Parameters of a type marked `redacted` print as `#redacted#`; everything else is printed as it is. Mark every
secret (passwords, tokens, keys) in the request's type before reporting parameters anywhere:

```ocaml
let login =
  {sql| SELECT id FROM users WHERE email = ? AND password_hash = ? |sql}
  |> Caqti.Templater.(static T.(t2 string (redacted string) -->? string))
(* reported as: "alice@example.com", #redacted# *)
```

**Connections.** There is one pool per label for the owner and one per login with a URL of its own, each opening
up to `database_pool_size` connections: with many databases, keep that product under the server's connection
limit. Idle connections are closed after `max_idle_age`.

**Lost databases.** A connection error drops the pool, and the next statement reconnects. If that fails too, the
pool backs off: statements fail right away with the last connection error, and after the wait a single statement
tries again. The wait doubles up to the maximum and resets once a statement reached the database.
`Pool.ping label` tells whether a database answers; `Pool.connect` only sets the pool up. `Veins.Connection.test url`
checks a URL without a pool, and `Pool.test database` every URL of a database before (or after) it is registered: a
failed test of the registered database sets its status to `ConnectionIssue`, the next successful one back to `Active`.

**Timeouts.** PostgreSQL URLs get `connect_timeout=5` (see above). caqti-driver-mariadb takes no timeout from the
URL: set `connect-timeout` (and `read-timeout` / `write-timeout`) in the `[caqti]` group of the client's `my.cnf`,
or another group named with `?config-group=` in the URL.

**TLS.** Veins doesn't touch the transport: for a database on another host, require TLS in the URL
(`?sslmode=verify-full` on PostgreSQL) or, for MariaDB, in the `my.cnf` group (`ssl-ca`, `ssl-verify-server-cert`).
`Url.pp` / `Url.show` mask the password, also one given as a `password` or `sslpassword` query parameter.

**Sharing the pools.** Code that expects Caqti's results instead of veins' exceptions, e.g. a framework that runs
its own statements, borrows a connection with `Db.Pool.use label f` (`?login` with roles). `f` gets a fixed
connection (`Veins.Connection.fixed`) and its result comes back as it is, `(_, Caqti.Error.t) result`. A lost
connection drops the pool and a pool that waits to reconnect gives an `Error` right away, as for every statement.
Only an unknown label or login raises. These errors aren't reported to `on_failure`.

---

## Multiple databases

_NOTE: `initialize` initiates the main database passed via `Pools.Make(Config)`_

```ocaml
let analytics =
  Database.create (Label.create "analytics") (Url.create analytics_url)

let () =
  Db.Pool.initialize ~additional_pools:[ analytics ] ();
  (* later: *)
  let%lwt rows = Db.collect (Db.label_ctx ~role:query (Label.create "analytics")) req () in
  ...
```

---

## Credits

The context design (`Veins.Ctx`: label, held connection and transaction contexts, the phantom transaction marker,
after-commit hooks) is Reynir Björnsson's database refactoring of the
[pool tool](https://github.com/uzh/z-pool-tool) ([#647](https://github.com/uzh/z-pool-tool/pull/647)), moved here
together with the pool tool's reconnect fixes.

## Development

The devcontainer mirrors the pool tool's setup (same base image, GitButler CLI, PAT-based git access). Copy
`.devcontainer/.env.example` to `.devcontainer/.env` and fill it in, then reopen the folder in the container.

```bash
# inside the container (the `make` alias uses .devcontainer/Makefile with the database URLs)
make deps
make build
make test
```

Both database servers run in `Europe/Zurich` on purpose, so the tests prove that veins pins every session to UTC.
The init scripts (`.devcontainer/init-*/01.sql`) create a `test` database and one user per role
(`veins_reader`, `veins_writer`, `veins_migrator`); they only run when the database volume is created, so remove
the `db-mariadb` / `db-postgres` volumes after changing them.

Environment variables used by the test suite (defaults match the devcontainer):

| Variable                                         | Default                                                     |
|--------------------------------------------------|-------------------------------------------------------------|
| `MARIADB_URL`                                    | `mariadb://admin:password@database-mariadb/development`     |
| `POSTGRES_URL`                                   | `postgresql://root:root@database-postgres/development`      |
| `MARIADB_{READER,WRITER,MIGRATOR}_URL`           | `MARIADB_URL` (a single all-rights user)                    |
| `POSTGRES_{READER,WRITER,MIGRATOR}_URL`          | `POSTGRES_URL` (a single all-rights user)                   |

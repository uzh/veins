# veins

Database connection pooling and schema migration library for OCaml.

- **Connection pools** — label-based multi-database pool management backed by [Caqti](https://github.com/paurkedal/ocaml-caqti) and Lwt
- **Migrations** — ordered, versioned, up/down migration steps with a global registry and drift detection
- **Dialect-specific packages** — install only the driver you need (`veins-mariadb` or `veins-postgresql`)
- **`veins-gen`** — CLI tool to generate migration file boilerplate

---

## Installation

```zsh
opam install veins-mariadb   # for MariaDB / MySQL
opam install veins-postgresql  # for PostgreSQL
```

Both pull in `veins` and the appropriate Caqti driver automatically. There is no need to depend on all three packages.

---

## Quick start

### 1. Define a pool

```ocaml
open Veins

(* The URL is typically read from an environment variable. *)
let url = Url.create (Sys.getenv "DATABASE_URL")
let db  = Database.create (Label.create "root") url

module Db = Veins_mariadb.Pools.Make (struct
  let database = db
  (* database_pool_size defaults to 10, expected_databases to 5 *)
end)

let () = Db.Pool.initialize ()
```

For custom pool sizes, or when you need to wire up the dialect yourself:

```ocaml
module Db = Veins.Pools.Make (struct
  module Dialect      = Veins_mariadb.Dialect
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
    ~logins:[ query_login, Url.create query_url; command_login, Url.create command_url ]
```

Several roles may share a login; the database then enforces only what the login is granted, and the types the rest.
A role claiming more than its login is granted passes the compiler, but the database refuses the statement:
`Error.Permission_denied` (MariaDB errors 1044, 1142, 1143, 1227, 1370; PostgreSQL SQLSTATE 42501, recognised by
the driver packages' dialects) names the label, login, role and declared needs.

## Migrations

### Generating a migration file

```zsh
veins-gen "add users table"
# → migration_20260424T140314_add_users_table.ml
```

Set `VEINS_MIGRATION_DIR` to write the file to a specific directory (defaults to the current directory):

```zsh
VEINS_MIGRATION_DIR=lib/migrations veins-gen "add users table"
# → lib/migrations/migration_20260424T140314_add_users_table.ml
```

The generated file:

```ocaml
open Veins

let migration =
  Migration.(
    create
      (Namespace.create "add_users_table")
      ~written_at:(ptime_of_string "2026-04-24T14:03:14Z")
    |> add_step
         (Step.create
            ~id:(Id.create "30d5a1e5-81eb-4de6-b81e-6f0695ab3421")
            ~label:"TODO: describe step 1"
            ~down:"TODO: reverse SQL"
            "TODO: forward SQL")
  )

let () = Migration.register migration
```

Edit the SQL strings, then link the file into your application. Every file that calls `Migration.register` contributes its steps to the global registry — no explicit list to maintain.

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

### Drift detection

```ocaml
(* Returns a list of drift values — Pending (steps not yet applied) or
   Orphaned (applied IDs no longer present in the registry). *)
let%lwt drifts = Runner.check (Label.create "root") () in
List.iter (function
  | Migration.Pending { namespace; pending_steps; _ } ->
    Printf.eprintf "pending: %s (%d steps)\n" (Migration.Namespace.show namespace) pending_steps
  | Migration.Orphaned { namespace; step_ids } ->
    Printf.eprintf "orphaned in %s: %d step(s)\n"
      (Migration.Namespace.show namespace) (List.length step_ids))
  drifts
```

---

## Packages

| Package            | Purpose                                                                                                   |
|--------------------|-----------------------------------------------------------------------------------------------------------|
| `veins`            | Core library — pools, migrations, dialect abstraction                                                     |
| `veins-mariadb`    | Pulls in `caqti-driver-mariadb`; provides `Veins_mariadb.Pools.Make` and `Veins_mariadb.Dialect`          |
| `veins-postgresql` | Pulls in `caqti-driver-postgresql`; provides `Veins_postgresql.Pools.Make` and `Veins_postgresql.Dialect` |

The `veins-gen` executable is installed as part of the `veins` package.

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

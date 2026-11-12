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

### 2. Run queries

```ocaml
let find_user id =
  let req = Caqti_type.(int ->? string) "SELECT name FROM users WHERE id = ?" in
  Db.find_opt (Label.create "root") req id

let create_user name =
  let req = Caqti_type.(string ->. unit) "INSERT INTO users (name) VALUES (?)" in
  Db.exec (Label.create "root") req name
```

### 3. Transactions

```ocaml
Db.transaction (Label.create "root") (fun () ->
  let%lwt () = Db.exec (Label.create "root") insert_req row in
  Lwt.return_unit)
```

---

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
let analytics = Database.create (Label.create "analytics") analytics_url

let () =
  Db.Pool.initialize ~additional_pools:[ analytics ] ();
  (* later: *)
  let%lwt rows = Db.collect (Label.create "analytics") req () in
  ...
```

---

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

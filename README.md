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
    empty
      (Namespace.create "add_users_table")
      ~written_at:(ptime_of_string "2026-04-24T14:03:14Z")
    |> add_step
         (step
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

(* Apply all pending migrations in chronological order. *)
let () = Lwt_main.run (Runner.run_all ())

(* Or run a single step forward/backward. *)
let () = Lwt_main.run (Runner.up ~id:(Migration.Id.create "30d5a1e5-...") ())
```

### Drift detection

```ocaml
(* Returns a list of steps that are recorded as applied in the database
   but are no longer present in the registry (e.g. deleted migration files). *)
let%lwt drifted = Runner.check () in
List.iter (fun d -> Printf.eprintf "drift: %s\n" (Migration.Id.value d.Migration.id)) drifted
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

Requires Docker (for the database services).

```bash
# Start services and enter the dev container (VS Code Dev Containers recommended)
# Then inside the container:

opam install . --deps-only --with-test
dune build @all
dune test
```

Environment variables used by the test suite (defaults match the devcontainer):

| Variable       | Default                                                     |
|----------------|-------------------------------------------------------------|
| `MARIADB_URL`  | `mariadb://admin:password@database-mariadb/development`     |
| `POSTGRES_URL` | `postgresql://admin:password@database-postgres/development` |

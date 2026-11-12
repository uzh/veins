# Veins — Agent Guidelines

Database connection-pooling and migration library for OCaml (OCaml 5, Lwt, Caqti).
Three opam packages: `veins` (core), `veins-mariadb`, `veins-postgresql`.

## Build & Test

```bash
make build          # dune build @all
make test           # dune test (needs live DBs — see below)
make format         # dune fmt (in-place)
make format-check   # dune build @fmt (CI check)
make doc            # odoc → _build/default/_doc/_html/
make lint-opam      # opam lint *.opam
make watch          # dune build @all --watch
make deps           # opam install . --deps-only --with-test
```

Integration tests require live MariaDB and PostgreSQL containers. All suites are `tests` stanzas, so `dune test` runs them.
Run a single suite with `dune build @test/unit/runtest` (or `test/mariadb`, `test/postgresql`).
Inside the devcontainer, use the `.devcontainer/Makefile` which pre-sets the correct URLs:

```bash
make -f .devcontainer/Makefile test
```

Outside the devcontainer, set env vars before `make test`:

```bash
MARIADB_URL=mariadb://admin:password@127.0.0.1/development \
POSTGRES_URL=postgresql://root:root@127.0.0.1/development \
make test
```

## Project Layout

| Path | Purpose |
|------|---------|
| `lib/` | Core library (`veins` package); `include_subdirs unqualified` |
| `lib/mariadb/` | `veins-mariadb` package — dialect + pre-configured `Pools.Make` |
| `lib/postgresql/` | `veins-postgresql` package — dialect + pre-configured `Pools.Make` |
| `bin/veins_gen.ml` | `veins-gen` CLI — generates migration file boilerplate |
| `test/unit/` | Tests without a database (run anywhere) |
| `test/common/` | Helpers shared by the integration suites (`veins_test_common`) |
| `test/mariadb/`, `test/postgresql/` | Integration suites per dialect (`test/common/suite.ml`), each links only its driver |
| `test/offline/` | Resilience and role checks against a fake server (MariaDB driver, no database) |
| `dune-project` | Source of truth for all three packages and their dependencies |

## Key Architecture

### Connection pools

`Veins.Pools.Make` is a functor over `Pools_sig.ConfigSig`:

```ocaml
module type ConfigSig = sig
  val database : Entity.Database.t (* primary DB — label becomes key *)
  val database_pool_size : int
  val expected_databases : int
  module Dialect : Dialect.Sig     (* not required with veins-mariadb/postgresql *)
end
```

Prefer the dialect packages for end users — they remove the `Dialect` field:

```ocaml
module Db = Veins_mariadb.Pools.Make (struct
  let database = Database.create (Label.create "root") url
  (* pool_size defaults to 10, expected_databases to 5 *)
end)
```

Call `Db.Pool.initialize ()` once at startup before any query.

### Contexts, requests, roles

Statements run on a `Veins.Ctx.t` (`label_ctx`, `connection_ctx`, `transaction_ctx`, `with_transaction`) and are
`Veins.Request.t` values (Caqti request + needed capabilities). On `Multiple` databases every context names a role,
and statements are checked against its capabilities before they are sent. The context design is Reynir
Björnsson's (uzh/z-pool-tool#647); keep the credit in `lib/ctx.mli`, `lib/pools.ml`, README and CHANGELOG.

Never use the driver's `rollback` or caqti's `with_transaction` directly: caqti-driver-mariadb 3.1 leaves
`autocommit` off after a rollback, `Pools.rollback` restores it (`Dialect.Sig.after_rollback`).

### Migrations

Steps are tracked individually by UUID (not per-namespace counters). `run_all` applies in `written_at` ascending order.

```ocaml
module Runner = Migration.Make (Db)
(* then: Runner.run_all, Runner.up, Runner.down, Runner.check, Runner.status, Runner.pending *)
```

Generate boilerplate with `veins-gen "label text"` → `migration_<timestamp>_<slug>.ml`.
New migration files call `Migration.register` — no explicit list to maintain.

### Dialects

`Dialect.Sig` provides DDL and DML strings. Both `Mariadb` and `Postgresql` implement it.
`Dialect.of_url : Entity.Url.t -> (module Dialect.Sig) option` infers dialect from the URL scheme.

### Error handling

Query helpers raise (not `result` returns): `Error.Failed` for what the database or driver reported (label, role,
untouched Caqti error; match with `Error.cause_of_exn`), `Error.Exn` for errors veins detects itself (unknown label,
missing role, missing capabilities). Only `Dialect.is_connection_error` errors drop and reconnect a pool.

## Conventions

- **`.ml` files have no doc-comments** on types or functions that duplicate what is already in the corresponding `.mli`. Keep implementation files lean.
- **Dialect SQL lives in `dialect.ml`** — never hardcode SQL strings in `migration.ml` or other modules.
- **`;;` terminators** are used after top-level `let` bindings in `lib/` (conventional profile, margin 90). See [.ocamlformat](.ocamlformat).
- **opam files are generated** — edit `dune-project`, never `.opam` files directly.
- **`include_subdirs unqualified`** is set on `lib/dune`; subdirectories that define their own library (mariadb/, postgresql/) must start their `dune` file with `(include_subdirs no)`.

## Generating Migrations

```bash
veins-gen "create orders table"
# → migration_20260424T143000_create_orders_table.ml
```

Edit the generated file: fill in SQL strings, adjust step labels. The file self-registers via `Migration.register` at the bottom — just link it into your binary.

## References

- [README.md](README.md) — installation, quick-start, usage examples
- [lib/pools_sig.mli](lib/pools_sig.mli) — full pool functor interface (`ConfigSig`, `Sig`, all query helpers)
- [lib/migration.mli](lib/migration.mli) — migration types, `RunnerSig`, step construction
- [lib/dialect.mli](lib/dialect.mli) — `Sig`, `Mariadb`, `Postgresql`, `of_url`
- [.devcontainer/docker-compose.yml](.devcontainer/docker-compose.yml) — database service definitions

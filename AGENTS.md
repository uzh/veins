# Vena — Agent Guidelines

Database connection-pooling and migration library for OCaml (OCaml 5, Lwt, Caqti).
Three opam packages: `vena` (core), `vena-mariadb`, `vena-postgresql`.

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

Integration tests require live MariaDB and PostgreSQL containers.
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
| `lib/` | Core library (`vena` package); `include_subdirs unqualified` |
| `lib/mariadb/` | `vena-mariadb` package — dialect + pre-configured `Pools.Make` |
| `lib/postgresql/` | `vena-postgresql` package — dialect + pre-configured `Pools.Make` |
| `bin/vena_gen.ml` | `vena-gen` CLI — generates migration file boilerplate |
| `test/` | Alcotest integration tests (MariaDB + PostgreSQL) |
| `dune-project` | Source of truth for all three packages and their dependencies |

## Key Architecture

### Connection pools

`Vena.Pools.Make` is a functor over `Pools_sig.ConfigSig`:

```ocaml
module type ConfigSig = sig
  val database : Entity.Database.t (* primary DB — label becomes key *)
  val database_pool_size : int
  val expected_databases : int
  module Dialect : Dialect.Sig     (* not required with vena-mariadb/postgresql *)
end
```

Prefer the dialect packages for end users — they remove the `Dialect` field:

```ocaml
module Db = Vena_mariadb.Pools.Make (struct
  let database = Database.create (Label.create "root") url
  (* pool_size defaults to 10, expected_databases to 5 *)
end)
```

Call `Db.Pool.initialize ()` once at startup before any query.

### Migrations

Steps are tracked individually by UUID (not per-namespace counters). `run_all` applies in `written_at` ascending order.

```ocaml
module Runner = Migration.Make (Db)
(* then: Runner.run_all, Runner.up, Runner.down, Runner.check, Runner.status, Runner.pending *)
```

Generate boilerplate with `vena-gen "label text"` → `migration_<timestamp>_<slug>.ml`.
New migration files call `Migration.register` — no explicit list to maintain.

### Dialects

`Dialect.Sig` provides DDL and DML strings. Both `Mariadb` and `Postgresql` implement it.
`Dialect.of_url : Entity.Url.t -> (module Dialect.Sig) option` infers dialect from the URL scheme.

### Error handling

Query helpers raise `Error.Exn` on failure (not `result` returns). Wrap explicit error boundaries in `Db.transaction`. The `Error.t` type has `Connection_failed`, `Not_found`, `Database_not_registered`.

## Conventions

- **`.ml` files have no doc-comments** on types or functions that duplicate what is already in the corresponding `.mli`. Keep implementation files lean.
- **Dialect SQL lives in `dialect.ml`** — never hardcode SQL strings in `migration.ml` or other modules.
- **`;;` terminators** are used after top-level `let` bindings in `lib/` (conventional profile, margin 90). See [.ocamlformat](.ocamlformat).
- **opam files are generated** — edit `dune-project`, never `.opam` files directly.
- **`include_subdirs unqualified`** is set on `lib/dune`; subdirectories that define their own library (mariadb/, postgresql/) must start their `dune` file with `(include_subdirs no)`.

## Generating Migrations

```bash
vena-gen "create orders table"
# → migration_20260424T143000_create_orders_table.ml
```

Edit the generated file: fill in SQL strings, adjust step labels. The file self-registers via `Migration.register` at the bottom — just link it into your binary.

## References

- [README.md](README.md) — installation, quick-start, usage examples
- [lib/pools_sig.mli](lib/pools_sig.mli) — full pool functor interface (`ConfigSig`, `Sig`, all query helpers)
- [lib/migration.mli](lib/migration.mli) — migration types, `RunnerSig`, step construction
- [lib/dialect.mli](lib/dialect.mli) — `Sig`, `Mariadb`, `Postgresql`, `of_url`
- [.devcontainer/docker-compose.yml](.devcontainer/docker-compose.yml) — database service definitions

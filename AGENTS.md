# Veins — Agent Guidelines

Database connection-pooling and migration library for OCaml (OCaml 5, Lwt, Caqti).
One opam package, `veins`, with three libraries: `veins` (core) and the optional `veins.mariadb` /
`veins.postgresql`, built when their Caqti driver is installed (`depopts`).

## Build & Test

```bash
make build          # dune build @all
make test           # dune test (needs live DBs — see below)
make format         # dune fmt (in-place)
make format-check   # dune build @fmt (CI check)
make doc            # odoc → _build/default/_doc/_html/veins/ (CI publishes it to GitHub Pages from main)
make lint-opam      # opam lint *.opam
make watch          # dune build @all --watch
make deps           # opam install . --deps-only --with-test
make release-check  # dune-release check (lint, build + tests of the package, CHANGELOG)
make opam-release   # on the release tag: dune-release distrib, publish distrib, opam pkg, opam submit
```

Integration tests require live MariaDB and PostgreSQL containers. All suites are `tests` stanzas, so `dune test` runs them.
A suite whose `MARIADB_URL` / `POSTGRES_URL` is unset is skipped (`Suite.require_url`), so the package's tests pass
without a database (opam-repository's CI, dune-release); the devcontainer sets the URLs.
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
| `lib/veins.mli` | The public interface: every module of `lib/` an application may use, in sections |
| `lib/plain.ml` | `Veins.Plain` — the pools without roles, logins and needs (one database user) |
| `lib/mariadb/` | `veins.mariadb` library (optional) — `Driver` (reads the driver's errors) + pre-configured `Pools.Make` / `Plain.Make` |
| `lib/postgresql/` | `veins.postgresql` library (optional) — `Driver` (reads the driver's errors) + pre-configured `Pools.Make` / `Plain.Make` |
| `bin/veins_gen.ml` | `veins-gen` CLI — options and writing the file |
| `bin/veins_gen_template.ml` | `veins_gen_template` library — the generated file's text (`render`), names, ids |
| `test/gen/` | `veins-gen`'s output as fixtures (diffed, `dune promote` to accept), compiled and linked |
| `test/unit/` | Tests without a database (run anywhere) |
| `test/common/` | Helpers shared by the integration suites (`veins_test_common`) |
| `test/mariadb/`, `test/postgresql/` | Integration suites per dialect (`test/common/suite.ml`), each links only its driver |
| `test/offline/` | Resilience and role checks against a fake server (MariaDB driver, no database) |
| `doc/index.mld` | Package landing page of the odoc docs (https://uzh.github.io/veins/) |
| `dune-project` | Source of truth for the package and its dependencies (drivers are `depopts`) |

## Key Architecture

### Connection pools

`Veins.Pools.Make` is a functor over `Pools_sig.ConfigSig`:

```ocaml
module type ConfigSig = sig
  val database : unit -> Entity.Database.t (* primary DB, called by Pool.initialize *)
  val database_pool_size : int
  val expected_databases : int
  module Driver : Driver.Sig       (* not required with Veins_mariadb / Veins_postgresql *)
end
```

Prefer the driver libraries for end users — they remove the `Driver` field:

```ocaml
module Db = Veins_mariadb.Pools.Make (struct
  let database () = Database.create (Label.create "root") url
  (* pool_size defaults to 10, expected_databases to 5 *)
end)
```

Call `Db.Pool.initialize ()` once at startup before any query. `database` is a function so that nothing reads the
configuration when the module is made: call it only from `Pool.initialize`.

`Pools.Make_with_options (Config) (struct let options = ... end)` takes a `Pool_options.t` (connection recycling,
`statement_timeout`, `acquire_timeout`, `reconnect_backoff`, `on_failure`); `Pools.Make` is that with `Pool_options.default`. New
tuning goes into `Pool_options`, not into `ConfigSig` (its consumers build that module by hand). The driver
libraries' `Pools.Make_with_options` / `Plain.Make_with_options` take `database` and `database_pool_size`.

`on_failure` is called where veins raises a statement's error (`fail`: `statement_error`, `statement_pool`,
`use_pool`), never where an error only passes through (`settle`'s `exception` arms), so each is reported once;
`Pool.ping` passes `~quiet:true`. Raise new statement errors through `fail`. `is_connection_error` (`Pools_sig.Sig`, and `failure.connection_error`)
answers for what a statement raised with the driver's `is_connection_error` that drops pools: keep the two in step.

A connection error drops only the pool it happened on (`settle` / `disconnect_entry ~pool`), then the pool backs
off: `fetch_key` fails fast until `retry_at`, then hands the new pool to one statement (`probe`) until that
settled. Every path that takes a pool from `fetch_key` must go through `settle` (or, returning results like
`Pool.use`, `record` / `record_exn`), or the probe is never released.
Caqti's `connect_pool` is lazy, only a statement (or `Pool.ping`) tells whether the database answers.

`Connection.test url` connects once without a pool; `Pool.test database` runs it for every URL of a database with
the pools' session settings, and is the only place veins changes a registered status itself (`Active` ↔
`ConnectionIssue`, and only when the tested database has the registered URLs). URLs become a `Uri.t` for connecting
through `Entity.Url.to_connect_uri` (PostgreSQL's `connect_timeout`), which `Veins.Url` doesn't expose.

### Contexts, requests, roles

Statements run on a `('txn, 'g) Veins.Ctx.t` (`label_ctx`, `connection_ctx`, `transaction_ctx`, `with_transaction`)
and are `Veins.Request.t` values (Caqti request + its `Need.t`). Every context names a `Role.t`; `'g` is the role's
closed set of polymorphic variant tags and a request's needs are a lower bound (``[> `Write ]``), so a statement the
role doesn't grant is a compile error. Nothing is checked at runtime; `test/typing` proves misuse doesn't compile,
add a case there when adding an entry point that takes `~needs` or a request. Each role connects as a `Login`;
`Database.create ?logins ?strict_logins label owner_url`, logins without a URL share the owner's pool (logged
once) or, with `~strict_logins:true`, raise `Error.Login_not_configured`. A database refusing a
statement the types allowed raises `Error.Permission_denied` (`Driver.is_permission_error`). The context design is
Reynir Björnsson's (uzh/z-pool-tool#647); keep the credit in `lib/ctx.mli`, `lib/pools.ml`, README and CHANGELOG.

Only a pool builds contexts. The constructors and what reaches into a context (its connection, its mutex, running
the after-commit hooks) are in `Ctx.Internal`, which `lib/veins.mli` removes from `Veins.Ctx`: an application can't
make a transaction context of a connection without a transaction, or pair a role with another login's connection.
Use `Ctx.Internal` from veins' own modules only.

caqti-driver-mariadb 3.1 leaves `autocommit` off after a rollback (also in caqti's `with_transaction`), and its
`populate` starts and commits a transaction of its own and doesn't roll back when a row fails. `Connection.fixed`
(`lib/connection.ml`) wraps a connection with these fixed, tracking whether a transaction is open from the
`start` / `commit` / `rollback` calls on the wrapper. `Pools` wraps every connection once per borrow from the
Caqti pool (`run`, `with_pool_connection`), so contexts and callbacks only ever see fixed connections: never pass
on a connection taken from the Caqti pool without it, and add new driver workarounds there.

### Migrations

Roll-forward only: no downs, a mistake is fixed by a new migration. Steps are tracked individually by UUID in `veins_migration_state`, one row per step, updated in place:
numeric `id`, `uuid`, `namespace`, `label`, `status` (`applied` / `failed`), `last_error`, `run_at`. A step without a
row is pending; a `failed` row blocks the set's runs until an admin repairs it by hand (`Migration.Repair`).

Applications use `Migration.App.Make (Db)` (default set, `Migration.register`) or `Migration.Sets.Make (S) (Db)`'s
`App` (typed sets, `register ~sets`): `migrate`, `dry_run`, `ready`, `report`, `check`, `ensure_clean`, `command`,
`Import.run`. There is no public runner below them: all of it is `Make_app` over `Make_internal` (state table, lock,
running steps), which `migration.mli` doesn't export; `Dry_run.decide` is the one place
that decides what `migrate` refuses (a `Refusal.t`; `dry_run`, `ready` / `Status.of_dry_run`, `check` and
`ensure_clean` read it too, so the startup check always agrees with `migrate`), so keep refusals there. Keep
application glue in veins, not in the consumers. Order is `Migration.order`: `written_at`, then namespace, the one timeline (no dependency graph).

`migrate` and `Import.run` go through `with_ctx`: one held
connection, the migration lock (`Dialect.try_lock`, session-scoped, so it must stay on that connection), the internal
upgrades, no statement timeout. `dry_run`, `ready`, `report`, `check` and `ensure_clean` go through `with_read_ctx` and must stay free of DDL, writes and locks (a read-only
login runs them; CI points `dry-run` at production).

**Internal upgrades** (`internal_upgrades` in `Make_internal`) are veins' own changes to its state table: an ordered
list, each detecting whether it's needed (`information_schema`), run (`setup`) under the lock before anything writes the
state: by `migrate` only once `Dry_run.decide` let it run (a refused run must not create the table, or an uninitialized
database stops being one), and by `Import.run`. Never tracked in the table.
A new change to the table is one more entry with its SQL in `dialect.ml`, plus a case in `read_rows` for the layout
before it (reads run without the upgrades) and a test upgrading every older layout. The upgrade to the current
layout is one-way.

Generate boilerplate with `veins-gen "label text"` → `migration_<YYYYMMDDhhmmss>_<slug>.ml`. SQL starting with
`TODO:` is a placeholder (`Sql.is_placeholder`): `migrate` treats it as missing SQL, so keep the generator's
placeholders starting with `TODO:`. Nothing else is (no comment or case handling, on purpose). New migration files
call `Migration.register` — no explicit list to maintain, but the library needs `-linkall`.

### Dialects

There is no dialect configuration: a Caqti 3 request renders its SQL from the dialect of the connection it runs on.
`Dialect` holds the SQL that differs (`Dialect.kind`: PostgreSQL, everything else MariaDB, since Caqti also renders
requests for printing with an `Unknown` dialect, so these functions must never fail) and `Dialect.request` builds
such a request. `Driver.Sig` is the only per-driver part: reading the driver's errors (`Veins_mariadb.Driver`,
`Veins_postgresql.Driver`, `Driver.Generic`).

### Error handling

Query helpers raise (not `result` returns): `Error.Failed` for what the database or driver reported (label, login,
role, untouched Caqti error; match with `Error.cause_of_exn`), `Error.Exn` for errors veins detects itself (unknown
label, failed migration) and for `Permission_denied`. Only `Driver.is_connection_error` errors drop and reconnect a
pool.

## Conventions

- **`lib/veins.mli` decides what is public.** A new module gets its alias there, in the section it belongs to; what
  only veins' own modules need stays out (a submodule removed there like `Ctx.Internal`, or a narrowed signature like
  `Url`, which hides `to_uri`). Doc references in signatures that are shown outside `Veins` (`pools_sig.mli`) name
  modules as `Veins.X`, so they resolve in the driver libraries' docs too.
- **containers over the stdlib**: `CCOption`, `CCList`, `CCResult`, `CCString`, `CCFun`, `CCHash` etc., not `Option`,
  `List`, …; only polymorphic `Hashtbl` tables stay (containers has no `CCHashtbl.create`; with a known key type use
  `CCHashtbl.Make`).
- **`.ml` files have no doc-comments** on types or functions that duplicate what is already in the corresponding `.mli`. Keep implementation files lean.
- **Dialect SQL lives in `dialect.ml`** — never hardcode dialect-specific SQL in `migration.ml` or other modules;
  build requests with `Dialect.request`.
- **`;;` terminators** are used after top-level `let` bindings in `lib/` (conventional profile, margin 90). See [.ocamlformat](.ocamlformat).
- **opam files are generated** — edit `dune-project`, never `.opam` files directly.
- **`CHANGELOG.md` headings** are `## [Unreleased]` and `## [X.Y.Z] - date`, links as references at the bottom:
  dune-release reads the version from the first heading (`scripts/bump-version.sh` writes them on release).
- **`include_subdirs unqualified`** is set on `lib/dune`; subdirectories that define their own library (mariadb/, postgresql/) must start their `dune` file with `(include_subdirs no)`.

## Generating Migrations

```bash
veins-gen "create orders table"
# → migration_20260424143000_create_orders_table.ml
veins-gen --steps 3 --dialect postgresql "create orders table"   # options before the description, -- ends them
```

`--steps N` writes N steps (default 1); `--dialect mariadb|postgresql` writes `Sql.only` placeholders, the default
`both` one `Sql.v` with a TODO per dialect. Edit the generated file: fill in SQL strings (a `TODO:` left fails
`migrate` and `dry_run`), adjust step labels. The file self-registers via
`Migration.register` at the bottom — link its library with `(library_flags (-linkall))`.

## References

- [README.md](README.md) — installation, quick-start, usage examples
- [KNOWN_ISSUES.md](KNOWN_ISSUES.md) — Caqti / driver limits, veins' workarounds, upstream issues (filed
  and drafts); update it when adding or dropping a workaround
- [lib/pools_sig.mli](lib/pools_sig.mli) — full pool functor interface (`ConfigSig`, `Sig`, all query helpers)
- [lib/migration.mli](lib/migration.mli) — migration types, sets, `App_sig`, step construction
- [lib/veins.mli](lib/veins.mli) — the public modules, by section
- [lib/dialect.mli](lib/dialect.mli) — `kind`, `request` and the SQL that differs per dialect
- [.devcontainer/docker-compose.yml](.devcontainer/docker-compose.yml) — database service definitions

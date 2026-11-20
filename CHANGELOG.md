# Changelog

The format is based on [Keep a Changelog](http://keepachangelog.com/) and this project adheres to [Semantic Versioning](http://semver.org/).

## [Unreleased](https://github.com/uzh/veins/tree/HEAD)

### Added

- API documentation on GitHub Pages: <https://uzh.github.io/veins/>, published from `main` by CI, with a package
  landing page (`doc/index.mld`).
- `is_connection_error : exn -> bool` in `Pools_sig.Sig` and `Plain.Sig`: whether what a statement raised means the
  database is unreachable, decided by the driver as when veins drops a pool (also a connection lost mid-statement,
  not only a failed connect).
- 💥 `Error.Acquire_timeout`: what a statement raises when no connection of its pool became free within
  `acquire_timeout` (was `Error.Connection_failed`), so an exhausted pool isn't taken for an outage:
  `is_connection_error` and `failure.connection_error` are `false` for it. `Pool.use` still returns a
  `` `Connect_failed `` for it.
- `Pool_options.failure.connection_error`: the same answer for `on_failure`, which can't call the pool module it
  configures.
- Migrations in an application, roll-forward only:
  - `Migration.App.Make (Db)` (the default set) and `Migration.Sets.Make (S) (Db)` for typed sets (`register ~sets`,
    a tag outside the sets doesn't compile; `App (struct let set_for = … end)`), with `migrate`, `dry_run`,
    `ready`, `report`, `check ~policy`, `ensure_clean` and `command` / `command_exit` (`up`, `dry-run`, `status`,
    `check`, exit codes 0 / 1 / 2).
  - Order: `written_at` is the one timeline, ties by namespace (`Migration.order`).
  - Failures: each step runs on its own; a failed step gets a `failed` row with `last_error` and blocks the set's
    runs until an admin repairs it by hand (`Migration.Repair` prints the statements per dialect).
  - Out of order: per set `` `Fail `` (default) or `` `Warn ``; `migrate ~allow_out_of_order`,
    `--allow-out-of-order` and the variable `ALLOW_OUT_OF_ORDER` allow a migration by name.
  - `Status.t` (`Ready`, `Pending`, `Blocked` with its `Refusal.t`) is what `migrate` would do; `ensure_clean`
    raises `Error.Exn (Migration_not_clean _)` at startup unless every database is `Ready`.
  - `dry_run`: what `migrate` would do, read-only, without the lock (CI preflight with a read-only login).
  - `Migration.Import` with `Import.Source` and `counter_state`: imports another engine's state once per database
    (`Import.run` of the application); a database with tables but no state table is refused as uninitialized, and
    `migrate` doesn't create the state table when it refuses. An import creates it, also when it has nothing to import.
    Veins doesn't write the previous engine's table: a rollback to a release that still runs that engine re-runs
    every migration added since the switch, so roll forward.
  - `Report.pending_counts` (pending steps per migration) and `Report.pending_total`.
- 💥 The migration state table's new layout: numeric `id` primary key, the step's UUID in `uuid`, `status`
  (`applied` / `failed`), `last_error`, `run_at`. Veins upgrades the table itself when a migration run or an import
  writes to it, numbering the rows by `created_at`, one way: once a database ran this version, releases on an older
  veins version can't read the table.
- 💥 `Error.Migration_not_clean`.

### Changed

- `Migration.Namespace.compare`.
- 💥 `Dialect`'s migration-state SQL follows the new layout: `select_state_rows`, `upsert_step_row`,
  the upgrade statements and the repair statements replace `select_applied_ids`,
  `select_applied_rows`, `insert_applied_step` and `delete_applied_step`.
- Migrations of the default set run in `written_at` order with
  ties by namespace (were in reverse registration order); two migrations for one database with the same namespace or
  step id are refused before a run applies anything, and the same namespace registered twice into the default set
  raises.
- `veins-gen` no longer writes a `down`, and its files say how to link them (`-linkall`).
- MariaDB: `populate` inserts its rows 100 per statement (was one statement per row); a failing row still leaves
  none of them.
- MariaDB: a commit takes one round trip (turning autocommit back on commits), the rollback one fewer (restoring
  autocommit unprepared); a failed commit rolls back. A pool's state is logged at debug level when it changes, no
  longer before every statement, and with `acquire_timeout` a statement that gets a free connection at once sets no
  timer.
- `Dynparam`'s documentation says to build requests whose SQL varies as `dynamic` or `direct`, not `static`.

### Removed

- 💥 The runner `Migration.Make` (`RunnerSig`: `run_all`, `up`, `down`, `mark_applied`, `verify`, `check`, `status`,
  `pending`) and `Migration.drift`: `Migration.App.Make` / `Migration.Sets.Make` do it all, and `Import` takes the
  place of `mark_applied`.
- 💥 `Step.t`'s `down` and `Step.create ?down`: roll-forward only, a mistake is fixed by a new migration.
- 💥 `Migration.register ?for_databases`, `database_target` and `target_applies_to`: register into the default
  set, or into typed sets with `Migration.Sets.Make`.
- 💥 `Migration.Counter_state` (`import`, `record`): veins no longer writes counter tables; reading one is
  `Migration.Import.counter_state`'s job.

## [0.2.0](https://github.com/uzh/veins/tree/0.2.0) - 2026-11-19

Entries marked 💥 break existing code. The context design (`Veins.Ctx`) is Reynir Björnsson's database
refactoring in [uzh/z-pool-tool#647](https://github.com/uzh/z-pool-tool/pull/647); the reconnect fixes come
from #624, #637 and #657 there.

### Added

- `Veins.Ctx` with `label_ctx`, `connection_ctx`, `transaction_ctx` and `with_transaction`: statements run on a
  context; nested transactions join the outer one, `Ctx.after_commit` hooks run after the commit.
- Typed roles (`Veins.Need`, `Veins.Role`, `Veins.Request`): a statement the context's role doesn't grant is a
  compile error. `Role.owner` runs everything.
- Logins with their own URLs: `Database.create ?logins ?strict_logins label owner_url`. Without a URL a login
  shares the owner's pool, or fails with `Error.Login_not_configured` under `~strict_logins:true`.
- `Veins.Plain`: pools without roles, logins or needs, for an application with one database user.
- `Veins.Caqti_encoders`: row types with custom encoders written as lists.
- Errors: `Error.Failed` (label, login, role, Caqti error; `Error.cause_of_exn`) and `Error.Permission_denied`
  when the database refuses a statement the types allowed.
- `Driver.is_connection_error` and `Driver.is_permission_error`, implemented by the driver libraries.
- `Pool_options` and `Pools.Make_with_options`: connection recycling, `statement_timeout`, `acquire_timeout`,
  `reconnect_backoff`. Also in `Veins_mariadb` / `Veins_postgresql`, for `Pools` and `Plain`.
- 💥 `Pool_options.on_failure`: called once with every error a statement raises, its redacted parameters included.
  A `Pool_options.t` record written out in full needs the new field.
- Reconnect backoff: a pool that lost its database fails fast for a growing while, then lets one statement retry.
- `Pool.use` (runs a function on a pooled connection and returns Caqti's result), `Pool.ping`, `Pool.test` and
  `Connection.test` (check a URL before registering it).
- `Connection.fixed`: works around caqti-driver-mariadb 3.1's `rollback`, `with_transaction` and `populate`;
  every connection veins hands out is one.
- `Connection.without_fk_checks` and `connection_transaction`.
- Migrations hold a database lock while they run (`VEINS_MIGRATION_LOCK_TIMEOUT`, default 600 s).
- `Runner.verify` and the drift `Unsupported` in `Runner.check`: steps without SQL for the connection's dialect.
- `Migration.Id.derive`, `Migration.step_ids`, `Runner.mark_applied` and `?migrations` on the runner functions.
- `Migration.Counter_state.Make`: imports and keeps up a counter-based migration table such as Sihl's.
- `Dialect.is_identifier`, `table_exists`, `try_lock` / `unlock`, `list_tables`, `truncate`, `drop`, and
  `Migration.state_table`.

### Changed

- 💥 One opam package: `veins.mariadb` and `veins.postgresql` are libraries of `veins`, built when their Caqti
  driver is installed. Depend on `veins` and the driver.
- 💥 `ConfigSig.database` is `unit -> Database.t`, called by `Pool.initialize`: write `let database () = …`.
- 💥 No dialect configuration: SQL is rendered from the connection's dialect. `ConfigSig` takes `module Driver`
  instead of `module Dialect`.
- 💥 Query helpers take a context and a `Request.t`; `query`, `populate`, `transaction` and `transaction_iter` take
  `~needs`.
- 💥 `Database.create` takes the owner's URL and `?logins` instead of `Main` / `Multiple`; `Database.t` is private.
  `Pool.fetch`, `connect` and `disconnect` take `?login` instead of `?role`.
- 💥 `Pool.drop`, `Pool.reset` and `Pool.disconnect` return `unit`.
- 💥 Migration SQL per dialect: `Step.create` takes `Sql.t` (`Sql.v ~mariadb ~postgresql ()`, `Sql.only`,
  `Sql.any`). A plain string becomes `Sql.any "…"`. Missing SQL, or SQL starting with `TODO:`, fails before
  anything is applied.
- 💥 `Step.create ?id`: a step without an id gets a derived one, so `Step.id` returns an option.
- 💥 `VEINS_MIGRATION_TABLE` must be a plain table name.
- `run_all ~migrations` keeps the given order.
- `veins-gen`: one step by default, `--steps N` and `--dialect`; each step is a named binding.
- `Runner.status`, `pending` and `check` only read, and no longer create the state table.
- Built on the Caqti 3 API, without `caqti.classic`.
- Pools connect lazily; connections are no longer closed after 100 uses, idle ones after 5 minutes.
- No more `SET time_zone`: both Caqti drivers pin sessions to UTC.
- `ocamlformat` is a dev dependency only; `mtime` is a dependency.

### Deprecated

- `Migration.Counter_state`, only meant for moving away from a counter-based migration table.

### Removed

- 💥 The opam packages `veins-mariadb` and `veins-postgresql`.
- 💥 `Veins.Databases`: the pools keep their own registry (`Pool.add`, `Pool.find`, `Pool.find_all`).
- 💥 `Dialect.Sig`, `Dialect.Mariadb`, `Dialect.Postgresql`, `Dialect.of_url` and `insert_row`.

### Fixed

- Only a broken connection invalidates a pool, and only the pool it happened on.
- A failed pool reconnects on the next call instead of failing forever.
- A pool is drained at most once; a second drain no longer hangs.
- `Pool.clear` closes the cleared pools' connections.
- `Pool.find_all` lists databases with per-login URLs, and adding one twice no longer leaks its pools.
- A migration step's foreign key checks are turned off on the step's own connection.
- `populate` on MariaDB inserts all rows or none and joins the surrounding transaction.
- MariaDB's server-side network errors (1152, 1154-1161) count as lost connections.
- `Url.pp` / `Url.show` mask `password` and `sslpassword` query parameters.
- PostgreSQL URLs get `connect_timeout=5`, so an unresponsive server no longer freezes the process.

## [0.1.0](https://github.com/uzh/veins/tree/d5451cd340c4c06efad73a91654abfca33c890c3) - 2026-04-27

The start of using the changelog. Preparations for our pilot version 0.1.0.

### Added

- Devcontainer with one database user per role.

### Changed

- Require caqti >= 3.0.
- The migration state table defaults to `veins_migration_state` (`VEINS_MIGRATION_TABLE` overrides it).

### Fixed

- The test suites run with `dune test`.
- CI connects to its service containers on `127.0.0.1`.
- The PostgreSQL init script used MariaDB syntax.

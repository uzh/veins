# Changelog

The format is based on [Keep a Changelog](http://keepachangelog.com/) and this project adheres to [Semantic Versioning](http://semver.org/).

## [Unreleased](https://github.com/uzh/veins/tree/HEAD)

### Added

- API documentation on GitHub Pages: <https://uzh.github.io/veins/>, published from `main` by CI, with a package
  landing page (`doc/index.mld`).
- `is_connection_error : exn -> bool` in `Pools_sig.Sig` and `Plain.Sig`: whether what a statement raised means the
  database is unreachable, decided by the driver as when veins drops a pool (also a connection lost mid-statement,
  not only a failed connect).
- `Pool_options.failure.connection_error`: the same answer for `on_failure`, which can't call the pool module it
  configures.

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

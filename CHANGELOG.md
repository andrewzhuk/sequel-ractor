# Changelog

All notable changes to sequel-ractor will be documented here.
Format roughly follows Keep-a-Changelog; versions follow SemVer.

## [Unreleased]

## [0.0.1] — 2026-05-27

Initial alpha. Covers the full standard event-handler workload
(INSERT / UPDATE / DELETE / SELECT / transactions / on_conflict /
pg_json / multi_insert / prepared statements / schema introspection)
from inside worker Ractors on Ruby 3.2+ against Sequel 5.84+.

### Added
- `SequelRactor.finalize!` — one-shot bootstrap that freezes
  Sequel's process-global registries and marks adapter classes
  Ractor-shareable. Idempotent.
- Auto-finalize on first `Sequel.connect` — no explicit ritual
  required for the common case.
- `SequelRactor.harden!(database:, models: true)` — combines
  `Database#freeze`, `Sequel::Model.freeze_descendants`, and
  `finalize!` into a single production-hardening call.
- Adapter coverage:
  - `postgres` (pg) — primary target, fully verified.
  - `sqlite` — Sequel-side patches in place; runtime connection
    still blocked upstream by the sqlite3 gem's C extension
    marking `open_v2` as `Ractor::UnsafeError`.
  - `mysql2` / `trilogy` — Sequel-side patches conditional on
    adapter being loaded; untested locally without a MySQL server.
- `fiber_concurrency` extension verified working in workers
  (extension must be loaded in main before workers spawn).
- 32 RSpec integration specs against a local Postgres.

### Patches installed against Sequel
- `Synchronize` — `Sequel.synchronize` no-ops in worker Ractors
  (registries are already finalized; the underlying Mutex isn't
  shareable).
- `Registries` — finalises `ADAPTER_MAP`, `SHARED_ADAPTER_MAP`,
  `Database::EXTENSIONS`, `Postgres::CONVERSION_PROCS`,
  `Postgres::PG_QUERY_TYPE_MAP`, `Database.@initialize_hook`,
  `Sequel::VIRTUAL_ROW`, `SPLIT_SYMBOL_CACHE`,
  `SQLite::SQLITE_TYPES`, `MySQL::MYSQL_TYPES`.
- `DatabasesArray` — worker `Database#initialize` auto-sets
  `keep_reference: false`.
- `SymbolCache` — `Sequel.split_symbol` recomputes once the cache
  is frozen.

### Known limitations
- `Sequel::Model` cannot cross Ractor boundaries — the Database /
  ConnectionPool chain holds a `Thread::Mutex`. Use raw datasets
  (`db[:table]...`) in worker handlers; keep models in main.
- `db.create_table` / other DDL inside a worker raises — the
  schema-generator block uses `instance_exec` on a Proc defined
  in main. Run migrations in main.
- `db.extension(:foo)` for extensions not yet loaded in main —
  extension setup runs Procs from main. Load extensions
  (`require "sequel/extensions/foo"`) in main before spawning
  workers.

### Upstream
- VirtualRow `freeze`-isn't-freeze bug identified in vanilla
  Sequel — patches and reproducer prepared in `upstream-pr/`,
  awaiting submission to jeremyevans/sequel.

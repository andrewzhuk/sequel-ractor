# sequel-ractor

Ractor compatibility shim for Sequel 5.x. Lets `Sequel.connect`, dataset
operations, transactions, and the `pg_json` extension work from inside
non-main Ractor workers — without any change to upstream Sequel.

## Status

**v0.0.1 — alpha, but covers real handler workloads.** All standard
event-handler operations (INSERT / UPDATE / DELETE / SELECT /
transactions / on_conflict / pg_json) work in workers. Some
main-process-only patterns (DDL inside workers, runtime extension
registration) intentionally don't — these belong in your bootstrap,
not your hot path.

## What works ✅

Verified by `spec/integration_spec.rb` (34 specs, all green):

- `Sequel.connect(url)` inside a worker Ractor
- Worker `db[:table].insert(...)` / `.update(...)` / `.delete` / `.first`
- Block-form WHERE: `db[:t].where { score > 10 }`
- `INSERT … ON CONFLICT DO NOTHING` (inbox-style dedup)
- `UPDATE … WHERE … RETURNING`
- `multi_insert(rows)` (bulk INSERT)
- `db.transaction { ... }` and `Sequel::Rollback` to abort
- `Sequel.like(:col, "prefix-%")`, ordering, limits, counts
- The `pg_json` extension when loaded in main before finalize
- Concurrent reads across many ractors (40k+ reads/sec measured)

## What doesn't work — and probably never should ❌

These are main-process-only patterns by design. Don't do them in
workers; do them at bootstrap.

- **DDL inside a worker** (`db.create_table(...)`): the schema-generator
  block uses `instance_exec` on a Proc defined in main, which Ractor
  rejects. Migrations belong in main.
- **`db.extension(:foo)` for extensions loaded AT runtime in worker**:
  extension setup runs Procs from main. **Workaround**: load extensions
  in main with `require "sequel/extensions/foo"` BEFORE spawning workers
  — then `db.extension(:foo)` in worker just attaches the
  already-loaded module.
- **Registering new adapters at runtime**: after `finalize!`, the
  adapter map is frozen.
- **`Sequel::Model` classes inside workers**: Sequel::Model carries
  substantial class-level state (`@dataset`, `@db`, plugin chains,
  validation procs, association configurations) that's deeply tied
  to a single Database instance and includes Procs not designed to
  cross Ractor boundaries. Auditing and patching this would be a
  separate 1–2 week project on top of this gem.

  **The practical pattern** (and the one we recommend): keep
  models in main for admin, HTTP layer, and complex business logic;
  use raw datasets (`db[:table].insert(...)`) in worker handlers
  for high-throughput event processing. This separation is sound
  architecturally even without Ractor — heavy ORM in API layer,
  thin queries in background workers.

  ```ruby
  # In main:
  class Person < Sequel::Model(DB[:people])
    validates_presence_of :email
    plugin :timestamps
  end

  # In worker (handler):
  Ractor.new(URL) do |url|
    db = Sequel.connect(url)
    # NOT: Person.create(...)
    db[:people].insert(name: "Ada", email: "ada@example.com")
    # Validation and timestamps run in main when the API layer
    # handles user input; workers process already-validated data.
  end
  ```

## Usage

Minimal — just require and go:

```ruby
require "sequel"
require "sequel/adapters/postgres"
require "sequel/extensions/pg_json"  # load extensions you need
require "sequel/ractor"

# First Sequel.connect (main OR worker) auto-finalises registries.
# No explicit ritual needed.

Ractor.new("postgres://localhost/mydb".freeze) do |url|
  db = Sequel.connect(url)
  db[:events].insert(payload: "hello")
  rows = db[:events].where { id > 100 }.order(:id).limit(50).all
  db.transaction { db[:audit].insert(action: "processed") }
  db.disconnect
end
```

Explicit lifecycle (if you want to lock registry state before
spawning a high-contention workload):

```ruby
SequelRactor.finalize!  # idempotent, safe to call multiple times
```

## Production hardening — `harden!`

Sequel itself ships two complementary "lock down" mechanisms:

  - `Database#freeze` — freezes the database's opts, pool config,
    dataset class, loggers, loaded extensions.
  - `Sequel::Model.freeze_descendants` (via the `:subclasses` plugin)
    — finalises associations and freezes every model class.

Combined with `SequelRactor.finalize!` they give a complete
"nothing about the data layer can change after boot" lockdown.
The `harden!` helper does the three in one call:

```ruby
require "sequel"
require "sequel/adapters/postgres"
require "sequel/ractor"

Sequel::Model.plugin :subclasses   # so freeze_descendants can find them

DB = Sequel.connect(ENV["DATABASE_URL"])
DB.extension :pg_json

# Define models, load app code...
Dir["./models/*.rb"].each { |f| require f }

# Lock everything down — one call.
SequelRactor.harden!(database: DB, models: true)
```

After `harden!`:

- Calling `DB.extension(...)` raises `FrozenError`.
- Adding new methods or hooks to a model class raises `FrozenError`.
- Registering a new Sequel adapter raises `FrozenError`.

These guarantees are useful **independently of Ractors** — they catch
accidental runtime mutation of the data-layer config in any
multi-threaded production app.

### Important: `harden!` ≠ Ractor-shareable models

A frozen model class is `frozen?` but **not** `Ractor.shareable?`.
Sequel::Model holds a reference to a `Sequel::Database`, which holds
a `ConnectionPool`, which holds a `Thread::Mutex`. Mutexes cannot
cross Ractor boundaries — by Ruby's design, not by this gem's
limitation.

So `harden!` does **not** unlock `Sequel::Model` use inside worker
Ractors. Use raw datasets (`db[:table].insert(...)`) in workers, and
keep models in main for admin / HTTP layer. See the limitations
section below.

## How it works

After `require "sequel/ractor"`, four patches are installed against
Sequel:

| patch | what it does |
|---|---|
| `Synchronize` | `Sequel.synchronize` becomes a yield-without-lock in worker Ractors (the underlying Mutex isn't shareable, and workers don't need to lock global state — bootstrap is done). |
| `Registries` | `SequelRactor.finalize!` freezes and marks shareable: `ADAPTER_MAP`, `SHARED_ADAPTER_MAP`, `Database::EXTENSIONS`, `Postgres::CONVERSION_PROCS`, `Postgres::PG_QUERY_TYPE_MAP`, `Database.@initialize_hook`, `VIRTUAL_ROW`, `SPLIT_SYMBOL_CACHE`. |
| `DatabasesArray` | Worker `Database#initialize` auto-sets `keep_reference: false` so it doesn't push into the (non-shareable) `Sequel::DATABASES` registry. |
| `SymbolCache` | `Sequel.split_symbol` recomputes (rather than caches) once the cache is frozen — avoids FrozenError on what was previously a lazy write. |

The trickiest one is `VIRTUAL_ROW`: `Sequel::SQL::VirtualRow < BasicObject`
defines `def initialize; freeze; end`, but BasicObject doesn't have
`Kernel#freeze` — so the `freeze` call falls through to its own
`method_missing` and silently does nothing. The object is therefore
NOT actually frozen in vanilla Sequel. `sequel-ractor` force-freezes
it via `Object.instance_method(:freeze).bind(vr).call`, then marks it
shareable. This is arguably an upstream bug — candidate for a tiny
PR to Sequel adding `extend ::Kernel` to VirtualRow or calling
`Object.instance_method(:freeze).bind(self).call` inside its
`initialize`.

## Trade-offs after `finalize!`

- You can NOT register new Sequel adapters at runtime.
- You can NOT call `Sequel::Database.after_initialize { ... }` at runtime
  with non-shareable Procs.
- `Sequel::DATABASES` only lists connections opened in main.
- Symbol-cache caching is disabled (recompute on every lookup; cost
  is ~microseconds and invisible on any I/O-bound query path).

These are all acceptable for production systems that complete their
Sequel-related configuration at boot and don't reconfigure at runtime.

## Performance

In `spec/hot_path_test.rb` on M1 / local Postgres:

| operation | throughput |
|---|---|
| 4 ractors × 1000 inserts (parallel) | ~30k inserts/s |
| 8 ractors × 250 reads each (concurrent SELECT) | ~40k reads/s |

These are with vanilla `db[:table].insert(...)` / `.where(...).first`
calls — the standard Sequel API, no special MicroDb-style shortcuts.

## Testing

Standalone (when the gem is extracted to its own repo):

```bash
bundle install
bundle exec rspec spec/
```

Inside a monorepo alongside other gems, sequel-ractor's specs MUST
run in their own subprocess — `SequelRactor.finalize!` is
process-global, so any sibling spec that expects a pristine Sequel
will break if both run in the same Ruby process. The repo's root
Rakefile handles the split:

```bash
rake spec:framework   # everything except sequel-ractor
rake spec:ractor      # sequel-ractor, isolated subprocess
rake spec             # both, sequenced
```

CI runs the same split via `.github/workflows/ci.yml`.

## Adapter coverage

| adapter | Sequel-side finalisers | works in worker today? |
|---|---|---|
| `postgres` (pg gem) | ✅ `CONVERSION_PROCS`, `PG_QUERY_TYPE_MAP` | ✅ verified, this is the primary target |
| `sqlite` (sqlite3 gem) | ✅ `SQLITE_TYPES` | ❌ blocked upstream — sqlite3's C extension marks `open_v2` as `Ractor::UnsafeError` |
| `mysql2` / `trilogy` | ✅ `MYSQL_TYPES` (conditional — only if adapter loaded) | ⚠ untested locally (no MySQL); Sequel-side patches in place |

The SQLite story is interesting: our Sequel-side patches make
`Sequel::SQLite::SQLITE_TYPES` Ractor-safe, but you still can't
`Sequel.connect("sqlite://path")` from a worker because the underlying
`sqlite3` gem refuses to call `sqlite3_open_v2` outside the main
Ractor. That's a C-extension level decision in the sqlite3 gem, not
something this shim can override. When sqlite3 lifts that restriction
(or someone writes a Ractor-safe alternative), Sequel-side will Just
Work.

## Roadmap

Each remaining task is isolated and additive — adding it doesn't
disturb what already works.

1. **MySQL coverage verification**: spec-level tests once mysql2 or
   trilogy is available in CI. Sequel-side patches already in place.
2. **Sequel::Model support**. Significant audit — model class-level
   state (@dataset, @columns, plugin chains, hooks) all need
   eager-init or shareable treatment. May be architecturally blocked
   by the `ConnectionPool` Mutex regardless — see "harden! ≠ Ractor-
   shareable models" above.
3. **Prepared statements API**: `db[:t].prepare(:foo, "...")` —
   covered by specs (see `spec/integration_spec.rb`).
4. **`Sequel.extension(:fiber_concurrency)` interaction**: confirm
   the fiber-aware pool inside a Ractor still works.
5. **Upstream PRs**: at minimum the VirtualRow `freeze`-isn't-freeze
   issue is worth a tiny PR — it's a real (latent) bug in vanilla
   Sequel.

## Contributing

If you hit `Ractor::IsolationError` from a Sequel call path this gem
doesn't cover:

1. Identify the constant or ivar from the error message.
2. Add a finalizer in `lib/sequel/ractor/patches/registries.rb`.
3. Add a spec in `spec/integration_spec.rb`.
4. Open a PR.

The fix is almost always: `Ractor.make_shareable(value)` plus
`Hash.freeze` if it's a registry.

## License

MIT.

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

**Requires Ruby 4.0+.** Earlier versions ship a Ractor API the gem
can't work around — specifically, `Ractor#value` doesn't exist yet
(it was `#take`), and `Method` objects can't be marked
`Ractor.make_shareable`. Sequel's `Postgres::CONVERSION_PROCS`
contains Method values, so workers fail to connect on Ruby 3.x.

## What works

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

## What doesn't work — and probably never should

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

## Locking down the data layer in production

In a long-running production app you almost never want to change
Sequel's config after boot. A misbehaving `require`, a hot-reload
path, a late-binding plugin call — any of these can mutate global
state and cause hard-to-debug bugs hours later. Sequel + this gem let
you make that state read-only once initialization is complete.

There are three things to freeze, in this order. You can do them
one by one (so you understand what each step costs), or call
`harden!` to do all three at once.

### Step 1: freeze the database

Once your app has connected and loaded all the extensions it needs,
call `freeze` on the `Database` object. Sequel ships this method out
of the box:

```ruby
DB = Sequel.connect(ENV["DATABASE_URL"])
DB.extension :pg_json
DB.extension :pg_array
# ... more extensions, more setup ...

DB.freeze
```

From now on:

```ruby
DB.extension(:something_else)
# => FrozenError: can't modify frozen Sequel::Postgres::Database

DB.loggers << my_logger
# => FrozenError: can't modify frozen Array

DB.opts[:single_threaded] = true
# => FrozenError: can't modify frozen Hash
```

The connection pool keeps working — queries, transactions, prepared
statements are all unaffected. Only **configuration** is locked.

### Step 2: freeze your models

If you use `Sequel::Model`, freeze every model subclass in one call.
This requires the `:subclasses` plugin (Sequel uses it to find them
all):

```ruby
# At the very top of your bootstrap, BEFORE any model is defined:
Sequel::Model.plugin :subclasses

# Define your models as usual:
class Person < Sequel::Model(DB[:people])
  validates_presence_of :email
  plugin :timestamps
end
# ... more models ...

# After every model file is loaded:
Sequel::Model.freeze_descendants
```

Now class-level mutations on any model raise `FrozenError`:

```ruby
Person.send(:define_method, :nickname) { name.split.first }
# => FrozenError: can't modify frozen class: Person

Person.plugin :validation_helpers
# => FrozenError on Person's plugin chain
```

Instance behaviour is unchanged — `Person.create(...)`, `person.save`,
`person.email = "..."` all still work. Only the **class** is sealed.

### Step 3: freeze the process-global registries

Sequel keeps several mutable Hashes for adapter and extension lookup
— `Sequel::ADAPTER_MAP`, `Sequel::Database::EXTENSIONS`, and a few
adapter-specific ones (`Postgres::CONVERSION_PROCS`, etc.). They
stay writable forever in vanilla Sequel. This gem freezes them:

```ruby
SequelRactor.finalize!
```

After this:

```ruby
require "sequel/adapters/some_new_one"
# => FrozenError: can't modify frozen Hash (Sequel::ADAPTER_MAP)

Sequel::Database.after_initialize { |db| db.opts[:trace] = true }
# => FrozenError on the @initialize_hook ivar
```

This step is also what makes worker Ractors safe: the registries
become not just frozen but `Ractor.shareable?`, so a worker can read
them when it calls `Sequel.connect(url)`.

### The shortcut: `harden!`

The three steps above are common enough that the gem bundles them
into one call:

```ruby
require "sequel"
require "sequel/adapters/postgres"
require "sequel/ractor"

Sequel::Model.plugin :subclasses

DB = Sequel.connect(ENV["DATABASE_URL"])
DB.extension :pg_json
Dir["./models/*.rb"].each { |f| require f }

# Equivalent to: DB.freeze + Sequel::Model.freeze_descendants + finalize!
SequelRactor.harden!(database: DB, models: true)
```

If you have multiple databases (e.g. read/write split), pass them
as `databases:`:

```ruby
SequelRactor.harden!(databases: [READ_DB, WRITE_DB], models: true)
```

If you don't use `Sequel::Model`, drop `models: true`:

```ruby
SequelRactor.harden!(database: DB)
```

You don't need workers or Ractors to benefit from this — `harden!` is
just as useful in a single-threaded Sinatra app to catch accidental
runtime mutation of data-layer config.

### Important: `harden!` ≠ Ractor-shareable models

A frozen model class is `frozen?` but **not** `Ractor.shareable?`.
Sequel::Model holds a reference to a `Sequel::Database`, which holds
a `ConnectionPool`, which holds a `Thread::Mutex`. Mutexes cannot
cross Ractor boundaries — by Ruby's design, not by this gem's
limitation.

So `harden!` does **not** unlock `Sequel::Model` use inside worker
Ractors. Use raw datasets (`db[:table].insert(...)`) in workers, and
keep models in main for admin / HTTP layer.

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
shareable.

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
calls — the standard Sequel API.

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
| `postgres` (pg gem) | `CONVERSION_PROCS`, `PG_QUERY_TYPE_MAP` | yes — primary target, fully verified |
| `sqlite` (sqlite3 gem) | `SQLITE_TYPES` | no — sqlite3's C extension marks `open_v2` as `Ractor::UnsafeError`, blocked upstream |
| `mysql2` / `trilogy` | `MYSQL_TYPES` (loaded only if adapter is required) | untested locally without a MySQL server; Sequel-side patches in place |

The SQLite story is interesting: the Sequel-side patches make
`Sequel::SQLite::SQLITE_TYPES` Ractor-safe, but you still can't
`Sequel.connect("sqlite://path")` from a worker because the underlying
`sqlite3` gem refuses to call `sqlite3_open_v2` outside the main
Ractor. That's a C-extension level decision in the sqlite3 gem, not
something this shim can override. When sqlite3 lifts that restriction
(or someone writes a Ractor-safe alternative), Sequel-side will just
work.

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

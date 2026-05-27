require "sequel"
require "sequel/adapters/postgres"
require "sequel/extensions/pg_json"
# Extensions that need to be present BEFORE finalize. After finalize,
# Sequel's registries and singleton methods are frozen, so any
# extension that mutates Sequel.* at load time must be loaded first.
# fiber_concurrency just does `Sequel.extend FiberConcurrency`, which
# is safe in main before workers spawn.
require "sequel/extensions/fiber_concurrency"
# Adapters too: after finalize, ADAPTER_MAP is frozen and
# `require "sequel/adapters/sqlite"` raises FrozenError when the
# sqlite adapter tries to register itself.
require "sequel/adapters/sqlite" rescue nil
require "sequel/ractor"

# Finalize once for the whole spec run. SequelRactor.finalize! is
# idempotent so this is safe even if other spec files call it too.
SequelRactor.finalize!

URL = ENV.fetch("MICRO_PG_TEST_URL", "postgres://127.0.0.1/micro_test").freeze

RSpec.describe "sequel-ractor integration" do
  before(:all) do
    @setup = Sequel.connect(URL)
    @setup.drop_table?(:sr_spec)
    @setup.create_table(:sr_spec) do
      primary_key :id
      String  :event_id, null: false, unique: true
      String  :status
      Integer :amount
      String  :payload
    end
  end

  after(:all) do
    @setup.drop_table?(:sr_spec)
    @setup.disconnect
  end

  before { @setup[:sr_spec].truncate }

  describe "basic connectivity" do
    it "opens Sequel inside a worker Ractor" do
      r = Ractor.new(URL) do |url|
        db = Sequel.connect(url)
        db_name = db.fetch("SELECT current_database() AS d").first[:d]
        db.disconnect
        db_name
      end
      # current_database() must match whatever DB the URL points at.
      # The URL is configurable via MICRO_PG_TEST_URL, so derive the
      # expected name instead of hard-coding it.
      require "uri"
      expected = URI.parse(URL).path.delete_prefix("/")
      expect(r.value).to eq(expected)
    end

    it "lets 4 workers run independent inserts in parallel" do
      ractors = 4.times.map do |rid|
        Ractor.new(URL, rid) do |url, my_id|
          db = Sequel.connect(url)
          250.times { |i| db[:sr_spec].insert(event_id: "p-#{my_id}-#{i}", status: "ok", amount: i) }
          db.disconnect
          my_id
        end
      end
      ractors.each(&:value)
      expect(@setup[:sr_spec].count).to eq(1_000)
    end
  end

  describe "transactions" do
    it "commits work inside a worker transaction" do
      Ractor.new(URL) do |url|
        db = Sequel.connect(url)
        db.transaction { db[:sr_spec].insert(event_id: "tx-c", status: "ok", amount: 1) }
        db.disconnect
      end.value
      expect(@setup[:sr_spec].where(event_id: "tx-c").count).to eq(1)
    end

    it "rolls back via Sequel::Rollback inside a worker transaction" do
      Ractor.new(URL) do |url|
        db = Sequel.connect(url)
        db.transaction do
          db[:sr_spec].insert(event_id: "tx-r", status: "ok", amount: 1)
          raise Sequel::Rollback
        end
        db.disconnect
      end.value
      expect(@setup[:sr_spec].where(event_id: "tx-r").count).to eq(0)
    end
  end

  describe "WHERE / ORDER / UPDATE / DELETE / RETURNING" do
    before do
      Ractor.new(URL) do |url|
        db = Sequel.connect(url)
        db[:sr_spec].insert(event_id: "a", status: "init", amount: 10)
        db[:sr_spec].insert(event_id: "b", status: "init", amount: 20)
        db[:sr_spec].insert(event_id: "c", status: "init", amount: 30)
        db.disconnect
      end.value
    end

    it "WHERE + first" do
      val = Ractor.new(URL) do |url|
        db = Sequel.connect(url)
        row = db[:sr_spec].where(amount: 20).first
        db.disconnect
        row[:event_id]
      end.value
      expect(val).to eq("b")
    end

    it "block-form WHERE (virtual_row)" do
      val = Ractor.new(URL) do |url|
        db = Sequel.connect(url)
        rows = db[:sr_spec].where { amount > 15 }.order(:amount).map { |r| r[:event_id] }
        db.disconnect
        rows
      end.value
      expect(val).to eq(%w[b c])
    end

    it "UPDATE … RETURNING" do
      val = Ractor.new(URL) do |url|
        db = Sequel.connect(url)
        result = db[:sr_spec].where(event_id: "a").returning(:status, :amount).update(status: "done")
        db.disconnect
        result.first
      end.value
      expect(val).to eq(status: "done", amount: 10)
    end

    it "DELETE with WHERE returns affected count" do
      val = Ractor.new(URL) do |url|
        db = Sequel.connect(url)
        n = db[:sr_spec].where(event_id: "c").delete
        db.disconnect
        n
      end.value
      expect(val).to eq(1)
      expect(@setup[:sr_spec].where(event_id: "c").count).to eq(0)
    end
  end

  describe "inbox-style dedup" do
    it "INSERT ON CONFLICT DO NOTHING is idempotent" do
      Ractor.new(URL) do |url|
        db = Sequel.connect(url)
        db[:sr_spec].insert_conflict.insert(event_id: "dup", status: "x", amount: 1)
        db[:sr_spec].insert_conflict.insert(event_id: "dup", status: "y", amount: 2)
        db.disconnect
      end.value
      expect(@setup[:sr_spec].where(event_id: "dup").count).to eq(1)
    end
  end

  describe "bulk operations" do
    it "multi_insert inserts many rows in one statement" do
      Ractor.new(URL) do |url|
        db = Sequel.connect(url)
        rows = (0...100).map { |i| { event_id: "m-#{i}", status: "ok", amount: i } }
        db[:sr_spec].multi_insert(rows)
        db.disconnect
      end.value
      expect(@setup[:sr_spec].where(Sequel.like(:event_id, "m-%")).count).to eq(100)
    end
  end

  describe "raw SQL escape hatches in worker" do
    it "db.fetch('SELECT ...').first" do
      val = Ractor.new(URL) do |url|
        db = Sequel.connect(url)
        row = db.fetch("SELECT 1 + 1 AS n").first
        db.disconnect
        row[:n]
      end.value
      expect(val).to eq(2)
    end

    it "db.fetch with placeholders" do
      val = Ractor.new(URL) do |url|
        db = Sequel.connect(url)
        row = db.fetch("SELECT ? AS upper", "hello").first
        db.disconnect
        row[:upper]
      end.value
      expect(val).to eq("hello")
    end

    it "db.run('RAW SQL') for one-shot commands" do
      Ractor.new(URL) do |url|
        db = Sequel.connect(url)
        db.run("SELECT pg_sleep(0)")
        db.disconnect
      end.value
      # Just smoke — verify db.run doesn't blow up in worker
      expect(true).to be true
    end

    it "Sequel.expr / Sequel.lit work in worker" do
      @setup[:sr_spec].insert(event_id: "se", status: "x", amount: 5)
      val = Ractor.new(URL) do |url|
        db = Sequel.connect(url)
        row = db[:sr_spec]
          .where(Sequel.lit("amount > ?", 3))
          .where(event_id: "se")
          .first
        db.disconnect
        row[:amount]
      end.value
      expect(val).to eq(5)
    end
  end

  describe "prepared statements" do
    it "db[:t].prepare(:insert) + .call(...) in worker" do
      Ractor.new(URL) do |url|
        db = Sequel.connect(url)
        ps = db[:sr_spec].prepare(:insert, :ps_ins,
                                  event_id: :$eid, status: :$st, amount: :$amt)
        100.times { |i| ps.call(eid: "ps-#{i}", st: "ok", amt: i) }
        db.disconnect
      end.value
      expect(@setup[:sr_spec].where(Sequel.like(:event_id, "ps-%")).count).to eq(100)
    end

    it "db[:t].prepare(:select_first) returning a single row in worker" do
      @setup[:sr_spec].insert(event_id: "ps-find", status: "ok", amount: 42)

      val = Ractor.new(URL) do |url|
        db = Sequel.connect(url)
        ps = db[:sr_spec].where(event_id: :$eid).prepare(:first, :ps_find)
        row = ps.call(eid: "ps-find")
        db.disconnect
        row[:amount]
      end.value
      expect(val).to eq(42)
    end
  end

  describe "schema introspection in workers" do
    it "db.tables works in worker" do
      tables = Ractor.new(URL) do |url|
        db = Sequel.connect(url)
        list = db.tables
        db.disconnect
        list
      end.value
      expect(tables).to include(:sr_spec)
    end

    it "db.table_exists?(:t) works in worker" do
      result = Ractor.new(URL) do |url|
        db = Sequel.connect(url)
        e = db.table_exists?(:sr_spec)
        db.disconnect
        e
      end.value
      expect(result).to be true
    end

    it "db.schema(:t) returns column info in worker" do
      cols = Ractor.new(URL) do |url|
        db = Sequel.connect(url)
        s = db.schema(:sr_spec)
        db.disconnect
        s.map { |name, _| name }
      end.value
      expect(cols).to include(:id, :event_id, :status, :amount, :payload)
    end

    it "db.indexes(:t) works in worker" do
      idx = Ractor.new(URL) do |url|
        db = Sequel.connect(url)
        i = db.indexes(:sr_spec)
        db.disconnect
        i
      end.value
      expect(idx).to be_a(Hash)
    end

    it "db.foreign_key_list(:t) works in worker" do
      fks = Ractor.new(URL) do |url|
        db = Sequel.connect(url)
        f = db.foreign_key_list(:sr_spec)
        db.disconnect
        f
      end.value
      expect(fks).to be_an(Array)
    end
  end

  describe "extensions" do
    it "pg_json round-trip in worker (extension loaded in main first)" do
      val = Ractor.new(URL) do |url|
        db = Sequel.connect(url)
        db.extension :pg_json
        db[:sr_spec].insert(
          event_id: "j", status: "ok", amount: 0,
          payload:  Sequel.pg_jsonb({ k: "v", n: 42 }).to_s,
        )
        row = db[:sr_spec].where(event_id: "j").first
        db.disconnect
        row[:payload]
      end.value
      expect(val).to include("BidPlaced").or include('"k"').or include('k:')
    end
  end

  describe "Adapter coverage beyond postgres" do
    # We can't connect to SQLite from a worker — sqlite3's C extension
    # marks #open_v2 as Ractor::UnsafeError. That's a constraint inside
    # the sqlite3 gem, not in Sequel. Our finalisers fix Sequel's side
    # so when sqlite3 lifts its restriction, things will just work.
    #
    # Same expected story for mysql2/trilogy.

    it "finalises Sequel::SQLite::SQLITE_TYPES if the adapter is loaded" do
      begin
        require "sequel/adapters/sqlite"
      rescue LoadError
        skip "sqlite3 gem not installed"
      end
      # We deliberately do NOT call reset! to avoid clobbering the
      # finalize state the rest of the suite depends on. Just verify
      # that after our finalise pass the constant is frozen and
      # readable from a worker.
      SequelRactor.finalize!
      expect(Sequel::SQLite::SQLITE_TYPES).to be_frozen

      r = Ractor.new do
        Sequel::SQLite::SQLITE_TYPES.size rescue $!.class.name
      end
      expect(r.value).to be_a(Integer)
    end

    it "is a no-op for adapter constants that aren't loaded" do
      # MySQL adapter file not required — branch should be skipped
      # without raising.
      expect { SequelRactor.finalize! }.not_to raise_error
    end
  end

  describe "SequelRactor.harden! production hardening" do
    it "freezes a single database via database:" do
      db = Sequel.connect(URL)
      SequelRactor.harden!(database: db)
      expect(db.frozen?).to be true
      db.disconnect
    end

    it "freezes multiple databases via databases:" do
      db1 = Sequel.connect(URL)
      db2 = Sequel.connect(URL)
      SequelRactor.harden!(databases: [db1, db2])
      expect(db1.frozen?).to be true
      expect(db2.frozen?).to be true
      db1.disconnect
      db2.disconnect
    end

    it "raises with a clear message if models: true is used without the :subclasses plugin" do
      # Stub out freeze_descendants to simulate no subclasses plugin loaded.
      allow(::Sequel::Model).to receive(:respond_to?).with(:freeze_descendants).and_return(false)
      expect {
        SequelRactor.harden!(models: true)
      }.to raise_error(::Sequel::Error, /:subclasses/)
    end

    it "is idempotent — second call is a no-op" do
      db = Sequel.connect(URL)
      SequelRactor.harden!(database: db)
      expect { SequelRactor.harden!(database: db) }.not_to raise_error
      db.disconnect
    end

    it "finalises registries as a side effect" do
      # finalize is process-global; finalized? should be true after harden!.
      SequelRactor.harden!
      expect(SequelRactor.finalized?).to be true
    end
  end

  describe "Sequel::Model — documented limitation, raw datasets are the workaround" do
    it "raw datasets work fine for the same workload" do
      val = Ractor.new(URL) do |url|
        db = Sequel.connect(url)
        # Equivalent of `Person.create(name: "Bob", age: 25).attributes` —
        # but using the raw dataset API that IS Ractor-safe.
        db[:sr_spec].insert(event_id: "via-dataset", status: "ok", amount: 25)
        row = db[:sr_spec].where(event_id: "via-dataset").first
        db.disconnect
        [row[:status], row[:amount]]
      end.value
      expect(val).to eq(["ok", 25])
    end
  end

  describe "fiber_concurrency extension in workers" do
    # The fiber_concurrency extension changes Sequel's per-thread
    # state key from Thread.current to Fiber.current. Sequel itself
    # is process-global, so loading the extension is a main-side act
    # — but it MUST keep working inside workers: queries must still
    # succeed, and Sequel.current must observe Fiber.current when the
    # worker runs the query from a non-root fiber.
    #
    # Loading the extension in main is the supported pattern (same
    # as pg_json). Loading it inside a worker would mutate a process-
    # global Sequel.singleton_class, which is racy and unsupported.

    it "Sequel.current returns Fiber in main and in worker" do
      expect(Sequel.current).to be_a(Fiber)

      worker_seen = Ractor.new do
        Sequel.current.class.name
      end.value
      expect(worker_seen).to eq("Fiber")
    end

    it "worker queries succeed after fiber_concurrency is loaded in main" do
      val = Ractor.new(URL) do |url|
        db = Sequel.connect(url)
        n = db.fetch("SELECT 42 AS n").first[:n]
        db.disconnect
        n
      end.value
      expect(val).to eq(42)
    end

    it "queries inside an explicit Fiber inside a worker still work" do
      val = Ractor.new(URL) do |url|
        db = Sequel.connect(url)
        result = nil
        Fiber.new {
          result = db.fetch("SELECT 7 AS n").first[:n]
        }.resume
        db.disconnect
        result
      end.value
      expect(val).to eq(7)
    end
  end

  describe "concurrent SELECT scaling" do
    before do
      @setup[:sr_spec].insert(event_id: "concurrent", status: "x", amount: 42)
    end

    # NOTE: kept at 4 ractors. Ruby 4.0.5's experimental Ractor VM
    # occasionally SEGVs when spawning 8+ ractors in rapid succession
    # during a test run — this is a Ruby VM bug, not a sequel-ractor
    # bug. The 4-ractor variant is stable here; higher counts work
    # fine in production code (Phase 6 benches at K=8 with N=10_000
    # succeed consistently because there's no test-runner overhead).
    it "4 ractors × 100 reads each, all return the same value" do
      results = 4.times.map do
        Ractor.new(URL) do |url|
          db = Sequel.connect(url)
          vals = 100.times.map { db[:sr_spec].where(event_id: "concurrent").first[:amount] }.uniq
          db.disconnect
          vals
        end
      end.map(&:value)
      expect(results).to all(eq([42]))
    end
  end
end

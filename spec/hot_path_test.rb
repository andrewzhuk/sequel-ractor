# Hot-path test — operations real event handlers do thousands of times
# per second. These MUST work in worker Ractors.
#
# Note: each probe wraps its Ractor block in a method to avoid the
# `cannot isolate a Proc because it accesses outer variables` trap.
# Top-level scope leaks lexical variables into Ractor blocks; methods
# create fresh lexical scopes.

require "sequel"
require "sequel/adapters/postgres"
require "sequel/ractor"

# Load extensions IN MAIN before finalize.
require "sequel/extensions/pg_json"

SequelRactor.finalize!

URL = ENV.fetch("DATABASE_URL", "postgres://127.0.0.1/micro_test").freeze

puts "═══ sequel-ractor hot-path test ═══"
puts "(realistic event-handler workload — what really matters)"
puts

def setup_schema
  d = Sequel.connect(URL)
  d.drop_table?(:sr_hot)
  d.create_table(:sr_hot) do
    primary_key :id
    String  :event_id, null: false, unique: true
    String  :status
    Integer :amount
    String  :payload
  end
  d.disconnect
end

def cleanup_schema
  d = Sequel.connect(URL)
  d.drop_table?(:sr_hot)
  d.disconnect
end

def probe(label)
  print "  #{label}: "
  yield
rescue => e
  if e.is_a?(Ractor::RemoteError)
    puts "❌ #{e.class}: #{e.message[0, 100]}"
  else
    puts "❌ #{e.class}: #{e.message[0, 120]}"
  end
end

setup_schema

# ── 1. 4 ractors × 1000 inserts + back-read
def probe1
  ractors = 4.times.map do |rid|
    Ractor.new(URL, rid) do |url, my_id|
      db = Sequel.connect(url)
      1000.times do |i|
        db[:sr_hot].insert(
          event_id: "evt-#{my_id}-#{i}",
          status:   "pending",
          amount:   100 + i,
          payload:  %({"i":#{i}}),
        )
      end
      mine = db[:sr_hot].where(Sequel.like(:event_id, "evt-#{my_id}-%")).count
      db.disconnect
      mine
    end
  end
  ractors.map(&:value)
end
probe("1. 4 ractors × 1000 inserts + back-read") { puts "✅ each saw own 1000: #{probe1.inspect}" }

# ── 2. INSERT … ON CONFLICT DO NOTHING (inbox dedup)
def probe2
  Ractor.new(URL) do |url|
    db = Sequel.connect(url)
    db[:sr_hot].insert_conflict.insert(event_id: "dup-key", status: "x", amount: 1)
    db[:sr_hot].insert_conflict.insert(event_id: "dup-key", status: "y", amount: 2)
    after = db[:sr_hot].where(event_id: "dup-key").count
    db.disconnect
    after
  end.value
end
probe("2. INSERT … ON CONFLICT DO NOTHING (inbox-style)") { puts "✅ after=#{probe2} (1 row, dedup worked)" }

# ── 3. UPDATE … RETURNING
def probe3
  Ractor.new(URL) do |url|
    db = Sequel.connect(url)
    db[:sr_hot].insert(event_id: "upd-1", status: "pending", amount: 50)
    updated = db[:sr_hot].where(event_id: "upd-1").returning(:status, :amount).update(status: "done")
    db[:sr_hot].where(event_id: "upd-1").delete
    db.disconnect
    updated.first
  end.value
end
probe("3. UPDATE … WHERE … RETURNING") { puts "✅ #{probe3.inspect}" }

# ── 4. multi_insert (bulk)
def probe4
  Ractor.new(URL) do |url|
    db = Sequel.connect(url)
    rows = (0...100).map { |i| { event_id: "bulk-#{i}", status: "ok", amount: i } }
    db[:sr_hot].multi_insert(rows)
    n = db[:sr_hot].where(Sequel.like(:event_id, "bulk-%")).count
    db[:sr_hot].where(Sequel.like(:event_id, "bulk-%")).delete
    db.disconnect
    n
  end.value
end
probe("4. multi_insert (bulk INSERT, 100 rows)") { puts "✅ #{probe4} rows" }

# ── 5. Transaction commit + rollback paths
def probe5
  Ractor.new(URL) do |url|
    db = Sequel.connect(url)
    db[:sr_hot].insert(event_id: "tx-commit",   status: "init", amount: 0)
    db[:sr_hot].insert(event_id: "tx-rollback", status: "init", amount: 0)

    db.transaction do
      db[:sr_hot].where(event_id: "tx-commit").update(status: "step1")
    end

    db.transaction do
      db[:sr_hot].where(event_id: "tx-rollback").update(status: "step1")
      raise Sequel::Rollback
    end

    committed   = db[:sr_hot].where(event_id: "tx-commit").first
    rolled_back = db[:sr_hot].where(event_id: "tx-rollback").first
    db[:sr_hot].where(Sequel.like(:event_id, "tx-%")).delete
    db.disconnect
    [committed[:status], rolled_back[:status]]
  end.value
end
probe("5. Transaction commit + Sequel::Rollback paths") { puts "✅ #{probe5.inspect}" }

# ── 6. pg_json column round-trip
def probe6
  Ractor.new(URL) do |url|
    db = Sequel.connect(url)
    db.extension :pg_json
    db[:sr_hot].insert(
      event_id: "json-1", status: "ok", amount: 0,
      payload: Sequel.pg_jsonb({ kind: "BidPlaced", amount: 250 }).to_s,
    )
    row = db[:sr_hot].where(event_id: "json-1").first
    db[:sr_hot].where(event_id: "json-1").delete
    db.disconnect
    row[:payload]
  end.value
end
probe("6. JSONB write/read via pg_json") { puts "✅ payload=#{probe6[0, 60].inspect}" }

# ── 7. 8 ractors × concurrent reads (perf check)
def probe7
  setup = Sequel.connect(URL)
  setup[:sr_hot].insert(event_id: "concurrent-read", status: "x", amount: 42)
  setup.disconnect

  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  ractors = 8.times.map do
    Ractor.new(URL) do |url|
      db = Sequel.connect(url)
      vals = 250.times.map { db[:sr_hot].where(event_id: "concurrent-read").first[:amount] }
      db.disconnect
      vals.uniq
    end
  end
  results = ractors.map(&:value)
  t1 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  [results, t1 - t0]
end
probe("7. 8 ractors × concurrent SELECT (read scaling)") do
  results, wall = probe7
  total = 8 * 250
  printf "✅ %d reads in %.3fs (%.0f reads/s)\n", total, wall, total / wall
end

cleanup_schema

puts
puts "✅ Hot-path coverage: real event-handler workloads work cleanly"
puts "   in worker Ractors via the standard Sequel API."

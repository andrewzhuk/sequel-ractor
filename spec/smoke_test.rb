# Smoke test for sequel-ractor.
#
# Same scenario as POC #3 in the framework's poc-ractor/ directory —
# but now with our patches loaded, Sequel should NOT crash inside a
# worker Ractor.

require "sequel"
require "sequel/adapters/postgres"   # eager-load the adapter we'll use
require "sequel/ractor"

# Bootstrap-complete signal — freezes registries, makes them safe to
# read from worker Ractors.
SequelRactor.finalize!

URL = ENV.fetch("DATABASE_URL", "postgres://127.0.0.1/micro_test")

puts "═══ sequel-ractor smoke test ═══"
puts "Sequel: #{Sequel::VERSION}, sequel-ractor: #{SequelRactor::VERSION}"
puts

# ── A. Sequel.connect inside a worker Ractor ────────────────────────
print "A. Sequel.connect inside Ractor: "
begin
  r = Ractor.new(URL.freeze) do |url|
    db = Sequel.connect(url)
    result = db.fetch("SELECT current_database() AS db").first[:db]
    db.disconnect
    result
  end
  puts "✅ #{r.value.inspect}"
rescue => e
  puts "❌ #{e.class}: #{e.message[0, 200]}"
  puts "   #{e.backtrace.first(3).join("\n   ")}" if e.backtrace
end

# ── B. 4 workers × independent connections + inserts ────────────────
print "B. 4 ractors × 2500 inserts (Sequel datasets): "
begin
  setup = Sequel.connect(URL)
  setup.drop_table?(:sr_smoke)
  setup.create_table(:sr_smoke) { Integer :i; String :ractor_id }
  setup.disconnect

  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  ractors = 4.times.map do |rid|
    Ractor.new(URL.freeze, rid) do |url, my_id|
      db = Sequel.connect(url)
      ds = db[:sr_smoke]
      2_500.times { |i| ds.insert(i: i, ractor_id: "r#{my_id}") }
      db.disconnect
      my_id
    end
  end
  ractors.map(&:value)
  t1 = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  verify = Sequel.connect(URL)
  got = verify[:sr_smoke].count
  verify.drop_table(:sr_smoke)
  verify.disconnect

  if got == 10_000
    printf "✅ %d/10000 rows  (%.0f inserts/s)\n", got, 10_000 / (t1 - t0)
  else
    puts "⚠️  Expected 10000 rows, got #{got}"
  end
rescue => e
  puts "❌ #{e.class}: #{e.message[0, 200]}"
  puts "   #{e.backtrace.first(5).join("\n   ")}" if e.backtrace
end

# ── C. Transactions + Sequel::Rollback ──────────────────────────────
print "C. Transactions with Sequel::Rollback in workers: "
begin
  setup = Sequel.connect(URL)
  setup.drop_table?(:sr_tx)
  setup.create_table(:sr_tx) { Integer :i }
  setup.disconnect

  ractors = 4.times.map do |rid|
    Ractor.new(URL.freeze, rid) do |url, my_id|
      db = Sequel.connect(url)
      ok = rolled = 0
      500.times do |i|
        db.transaction do
          db[:sr_tx].insert(i: i)
          raise Sequel::Rollback if i % 7 == 0
        end
        i % 7 == 0 ? rolled += 1 : ok += 1
      end
      db.disconnect
      [ok, rolled]
    end
  end
  results = ractors.map(&:value)
  ok_total    = results.sum { |o, _| o }
  rolled_total = results.sum { |_, r| r }

  v = Sequel.connect(URL)
  rows = v[:sr_tx].count
  v.drop_table(:sr_tx)
  v.disconnect

  if rows == ok_total
    puts "✅ #{rows} committed, #{rolled_total} rolled back"
  else
    puts "⚠️  rows=#{rows}, expected ok_total=#{ok_total}"
  end
rescue => e
  puts "❌ #{e.class}: #{e.message[0, 200]}"
end

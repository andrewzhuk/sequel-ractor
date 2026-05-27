# Deep smoke test — more advanced Sequel features that handlers
# actually use. Each probe surfaces new Ractor::IsolationError sources
# we can then patch.

require "sequel"
require "sequel/adapters/postgres"
require "sequel/ractor"
SequelRactor.finalize!

URL = ENV.fetch("DATABASE_URL", "postgres://127.0.0.1/micro_test")

puts "═══ sequel-ractor deep test ═══"
puts

def probe(label)
  print "  #{label}: "
  yield
rescue => e
  if e.is_a?(Ractor::RemoteError)
    puts "❌ #{e.class}: #{e.message[0, 80]}"
  else
    puts "❌ #{e.class}: #{e.message[0, 120]}"
  end
end

# ── 1. SELECT with WHERE clause ──────────────────────────────────────
setup = Sequel.connect(URL)
setup.drop_table?(:sr_deep)
setup.create_table(:sr_deep) do
  primary_key :id
  String   :name
  Integer  :score
  DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
end
setup[:sr_deep].insert(name: "alice", score: 10)
setup[:sr_deep].insert(name: "bob",   score: 20)
setup[:sr_deep].insert(name: "carol", score: 30)
setup.disconnect

probe "1. SELECT with WHERE (db[:t].where(:score=>20).first)" do
  r = Ractor.new(URL.freeze) do |url|
    db = Sequel.connect(url)
    row = db[:sr_deep].where(score: 20).first
    db.disconnect
    row[:name]
  end
  puts "✅ #{r.value.inspect}"
end

probe "2. SELECT with ORDER BY + LIMIT" do
  r = Ractor.new(URL.freeze) do |url|
    db = Sequel.connect(url)
    rows = db[:sr_deep].order(Sequel.desc(:score)).limit(2).map { |r| r[:name] }
    db.disconnect
    rows
  end
  puts "✅ #{r.value.inspect}"
end

probe "3. Count / aggregate" do
  r = Ractor.new(URL.freeze) do |url|
    db = Sequel.connect(url)
    total = db[:sr_deep].count
    avg   = db[:sr_deep].avg(:score).to_f
    db.disconnect
    [total, avg]
  end
  puts "✅ #{r.value.inspect}"
end

probe "4. UPDATE with WHERE" do
  r = Ractor.new(URL.freeze) do |url|
    db = Sequel.connect(url)
    n = db[:sr_deep].where(name: "bob").update(score: 25)
    after = db[:sr_deep].where(name: "bob").first[:score]
    db.disconnect
    [n, after]
  end
  puts "✅ #{r.value.inspect}"
end

probe "5. DELETE with WHERE" do
  r = Ractor.new(URL.freeze) do |url|
    db = Sequel.connect(url)
    n = db[:sr_deep].where(name: "carol").delete
    remaining = db[:sr_deep].count
    db.disconnect
    [n, remaining]
  end
  puts "✅ #{r.value.inspect}"
end

probe "6. INSERT … RETURNING id" do
  r = Ractor.new(URL.freeze) do |url|
    db = Sequel.connect(url)
    id = db[:sr_deep].returning(:id).insert(name: "dave", score: 99).first[:id]
    db.disconnect
    id
  end
  puts "✅ id=#{r.value}"
end

probe "7. Sequel.expr / complex WHERE (Sequel[:score] > 15)" do
  r = Ractor.new(URL.freeze) do |url|
    db = Sequel.connect(url)
    n = db[:sr_deep].where { score > 15 }.count
    db.disconnect
    n
  end
  puts "✅ #{r.value}"
end

probe "8. Block-form WHERE with virtual row" do
  r = Ractor.new(URL.freeze) do |url|
    db = Sequel.connect(url)
    rows = db[:sr_deep].where { score >= 20 }.order(:name).map { |r| r[:name] }
    db.disconnect
    rows
  end
  puts "✅ #{r.value.inspect}"
end

probe "9. Multi-table INSERT inside transaction" do
  r = Ractor.new(URL.freeze) do |url|
    db = Sequel.connect(url)
    # Make secondary table
    db.create_table?(:sr_deep_log) { primary_key :id; String :msg }
    db.transaction do
      db[:sr_deep].insert(name: "edna", score: 50)
      db[:sr_deep_log].insert(msg: "inserted edna")
    end
    counts = [db[:sr_deep].count, db[:sr_deep_log].count]
    db.drop_table(:sr_deep_log)
    db.disconnect
    counts
  end
  puts "✅ #{r.value.inspect}"
end

probe "10. JSON column (pg_json extension)" do
  r = Ractor.new(URL.freeze) do |url|
    db = Sequel.connect(url)
    db.extension :pg_json
    db.create_table?(:sr_deep_json) { primary_key :id; jsonb :payload }
    db[:sr_deep_json].insert(payload: Sequel.pg_jsonb({ foo: "bar", n: 42 }))
    row = db[:sr_deep_json].first
    db.drop_table(:sr_deep_json)
    db.disconnect
    row[:payload].to_h
  end
  puts "✅ #{r.value.inspect}"
end

# Cleanup
final = Sequel.connect(URL)
final.drop_table?(:sr_deep)
final.disconnect

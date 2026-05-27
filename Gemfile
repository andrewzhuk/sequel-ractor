source "https://rubygems.org"

# Gem dependencies are declared in sequel-ractor.gemspec.
gemspec

group :development, :test do
  gem "rspec", "~> 3.13"
  gem "rake",  "~> 13.2"
  # Postgres adapter — the primary target. Integration specs
  # connect to a local Postgres at MICRO_PG_TEST_URL (defaults
  # to postgres://127.0.0.1/micro_test).
  gem "pg",      "~> 1.5"
  # SQLite adapter — exercised by the "adapter coverage" specs to
  # verify finalisers don't crash when SQLite is loaded. Worker
  # connections still blocked upstream by sqlite3's C extension.
  gem "sqlite3", "~> 2.0"
end

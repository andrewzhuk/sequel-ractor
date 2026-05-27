require "sequel"
require_relative "ractor/version"
require_relative "ractor/patches"

# Ractor compatibility shim for Sequel.
#
# Quick start (two lines in your bootstrap):
#
#   require "sequel/adapters/postgres"
#   require "sequel/ractor"
#
# That's it. The first `Sequel.connect` (from main or from a worker)
# auto-finalises the global registries — no explicit ritual.
#
# If you want explicit control (e.g. to lock in registry state before
# spawning workers under contention), call `SequelRactor.finalize!`
# yourself in your bootstrap.
#
# After finalize, worker Ractors can use the full Sequel dataset API:
#
#   Ractor.new(url) do |u|
#     db = Sequel.connect(u)
#     db[:users].where(active: true).order(:id).limit(100).all
#     db.transaction { db[:audit].insert(...) }
#     db.disconnect
#   end
#
# See README for the full list of what works, what doesn't, and why.
module SequelRactor
  class << self
    # One-shot bootstrap completion. Idempotent — safe to call from
    # multiple boot paths.
    def finalize!
      return self if @finalized
      @finalize_mutex ||= Mutex.new
      @finalize_mutex.synchronize do
        return self if @finalized   # double-check after lock
        Patches::Registries.finalize!
        @finalized = true
      end
      self
    end

    def finalized?
      @finalized == true
    end

    # For tests — un-freeze and re-enable mutation. NOT safe in
    # production after workers have started; intended only for test
    # suites that want to run pre- and post-finalize scenarios in
    # the same process.
    def reset!
      Patches::Registries.reset!
      @finalized = false
    end

    # Production hardening — one call to lock everything down.
    # Combines three native + one-of-our-own steps:
    #
    #   1. `Sequel::Model.freeze_descendants` (if models: true)  — Sequel
    #      built-in, requires :subclasses plugin loaded beforehand.
    #      Finalises associations and freezes every model class.
    #
    #   2. `Database#freeze` on each given database — Sequel built-in.
    #      Freezes opts, loggers, pool config, dataset_class, etc.
    #      After this nothing about the connection / schema config can
    #      change at runtime; any attempt raises FrozenError.
    #
    #   3. `SequelRactor.finalize!` — this gem.
    #      Freezes Sequel's process-global registries and marks adapter
    #      classes Ractor-shareable.
    #
    # Recommended bootstrap shape:
    #
    #   Sequel::Model.plugin :subclasses
    #   DB = Sequel.connect(ENV["DATABASE_URL"])
    #   DB.extension :pg_json
    #   Dir["./models/*.rb"].each { |f| require f }
    #
    #   SequelRactor.harden!(database: DB, models: true)
    #
    # Compatible with multi-database apps:
    #
    #   SequelRactor.harden!(databases: [READ_DB, WRITE_DB])
    #
    # Important: hardening Sequel::Model does NOT make models
    # Ractor-shareable. The Database / ConnectionPool chain still
    # contains a Mutex which cannot cross Ractor boundaries. Use raw
    # datasets in worker code; use models in main only. See README.
    def harden!(database: nil, databases: nil, models: false)
      dbs = Array(databases) | Array(database)
      dbs.each { |db| db.freeze unless db.frozen? }

      if models
        unless defined?(::Sequel::Model) && ::Sequel::Model.respond_to?(:freeze_descendants)
          raise ::Sequel::Error,
                "harden!(models: true) requires Sequel::Model.plugin :subclasses " \
                "to be called in your bootstrap before any model class is defined."
        end
        ::Sequel::Model.freeze_descendants
      end

      finalize!
      self
    end
  end
end

# Auto-finalize on first `Sequel.connect` call so users don't have to
# remember the explicit `SequelRactor.finalize!`. This means: as soon
# as the first connection happens, all registries are frozen and we
# can safely spawn workers.
#
# Users who prefer explicit lifecycle (e.g. to control timing of the
# freeze) can still call `SequelRactor.finalize!` from their boot
# code; the auto path is a no-op once already finalised.
module SequelRactor
  module AutoFinalize
    def connect(*args, **opts, &blk)
      ::SequelRactor.finalize! unless ::SequelRactor.finalized?
      super
    end
  end
end
Sequel.singleton_class.prepend(SequelRactor::AutoFinalize)

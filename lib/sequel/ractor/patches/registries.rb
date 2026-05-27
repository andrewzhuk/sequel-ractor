module SequelRactor
  module Patches
    # Finalisation of Sequel's global registry Hashes so worker Ractors
    # can read them safely.
    #
    # Constants targeted (exact locations in Sequel 5.104):
    #
    #   Sequel::ADAPTER_MAP                (lib/sequel/database.rb)
    #   Sequel::SHARED_ADAPTER_MAP         (lib/sequel/database.rb)
    #   Sequel::Database::EXTENSIONS       (lib/sequel/database/misc.rb)
    #
    # All three are mutable Hashes mutated at adapter / extension load
    # time. Once boot is complete, no further mutation is needed in
    # most apps — but the Hashes stay mutable forever and the values
    # (Classes / Modules) aren't marked shareable, so non-main Ractors
    # that do `Sequel.connect(url)` hit Ractor::IsolationError.
    #
    # `SequelRactor.finalize!` does the one-shot bootstrap-complete:
    #
    #   1. Walk each registry's values and Ractor.make_shareable them
    #      (no-op when already shareable).
    #   2. Freeze each Hash.
    #
    # After finalize, workers can read the maps via normal `[]` lookup
    # without crashing. Attempts to register a new adapter or extension
    # post-finalize raise FrozenError with a clear message.
    module Registries
      @installed = false

      class << self
        def install!
          @installed = true
        end

        def installed?
          @installed
        end

        # Called from SequelRactor.finalize!. Idempotent.
        def finalize!
          unless installed?
            raise "SequelRactor::Patches::Registries not installed yet"
          end
          finalize_map!(::Sequel::ADAPTER_MAP,         "Sequel::ADAPTER_MAP")
          finalize_map!(::Sequel::SHARED_ADAPTER_MAP,  "Sequel::SHARED_ADAPTER_MAP")
          if ::Sequel::Database.const_defined?(:EXTENSIONS)
            finalize_map!(::Sequel::Database::EXTENSIONS,
                          "Sequel::Database::EXTENSIONS")
          end

          # Adapter-specific registries. We finalize only the ones that
          # are actually loaded — touching un-loaded adapter constants
          # would unnecessarily require their files. Each adapter that
          # ships with Sequel has its own mutable Hashes / arrays of
          # type-conversion procs.
          finalize_postgres! if defined?(::Sequel::Postgres)
          finalize_sqlite!   if defined?(::Sequel::SQLite)
          finalize_mysql!    if defined?(::Sequel::MySQL)

          finalize_database_class_ivars!
          finalize_misc_constants!
          true
        end

        def finalize_misc_constants!
          finalize_virtual_row!
        end

        # Sequel::VIRTUAL_ROW is a Sequel::SQL::VirtualRow singleton.
        # VirtualRow < BasicObject, and inside its `initialize` it
        # calls `freeze` — but BasicObject doesn't have Kernel#freeze,
        # so that call falls through to its own method_missing and
        # returns a Sequel::SQL::Identifier instead of freezing the
        # object. The object is therefore NOT actually frozen, and
        # `Ractor.make_shareable` bails with "freeze does not freeze
        # object correctly".
        #
        # This is arguably an upstream bug — `freeze` in initialize is
        # a no-op. We work around it by force-freezing the singleton
        # via Object's bound method, bypassing method_missing.
        #
        # After force-freeze the object has no mutable IVs (it's a
        # BasicObject with included module methods only), so it
        # becomes Ractor-shareable cleanly.
        def finalize_virtual_row!
          return unless ::Sequel.const_defined?(:VIRTUAL_ROW, false)
          vr = ::Sequel::VIRTUAL_ROW

          # Bypass method_missing — bind the real Kernel#freeze.
          frozen_check = ::Object.instance_method(:frozen?).bind(vr).call
          unless frozen_check
            ::Object.instance_method(:freeze).bind(vr).call
          end

          # Now make_shareable works.
          ::Ractor.make_shareable(vr)
        rescue ::Ractor::Error => e
          warn "[sequel-ractor] could not make Sequel::VIRTUAL_ROW shareable: #{e.message}"
        end

        # Class-level ivars on Sequel::Database that the initialize
        # path reads from worker Ractors. Default values are usually
        # Procs / Hashes that aren't shareable but ARE deterministic;
        # we freeze + mark them shareable. After this, registering
        # additional hooks (e.g. via `after_initialize { ... }`)
        # requires the user to provide shareable Procs.
        CLASS_IVARS_TO_SHAREABLE = %i[
          @initialize_hook
        ].freeze

        def finalize_database_class_ivars!
          CLASS_IVARS_TO_SHAREABLE.each do |iv|
            next unless ::Sequel::Database.instance_variable_defined?(iv)
            current = ::Sequel::Database.instance_variable_get(iv)
            begin
              shareable = ::Ractor.make_shareable(current)
              ::Sequel::Database.instance_variable_set(iv, shareable)
            rescue ::Ractor::Error => e
              warn "[sequel-ractor] could not make #{iv} shareable: #{e.message}"
            end
          end
        end

        # Inverse — used by tests. Re-allow mutation by replacing each
        # registry with an unfrozen dup. NOT safe in production.
        def reset!
          targets = [
            [::Sequel,           :ADAPTER_MAP],
            [::Sequel,           :SHARED_ADAPTER_MAP],
            [::Sequel::Database, :EXTENSIONS],
          ]
          targets.each do |mod, name|
            next unless mod.const_defined?(name, false)
            current = mod.const_get(name)
            next unless current.frozen?
            mod.send(:remove_const, name)
            mod.const_set(name, current.dup)
          end
        end

        private

        # PG adapter has several mutable constants read during
        # Database#connect / #initialize. Mark all known ones shareable
        # so worker Ractors can open PG connections.
        #
        # Coverage: matches the constants in Sequel 5.104's
        # adapters/postgres.rb + adapters/shared/postgres.rb. If a
        # future Sequel version adds more, they'll surface as
        # Ractor::IsolationError with a clear constant name — file a
        # patch on this method.
        def finalize_postgres!
          if ::Sequel::Postgres.const_defined?(:CONVERSION_PROCS, false)
            finalize_map!(::Sequel::Postgres::CONVERSION_PROCS,
                          "Sequel::Postgres::CONVERSION_PROCS")
          end

          # PG::TypeMapByClass — read-only after construction; just
          # mark shareable so workers can read the constant.
          if ::Sequel::Postgres.const_defined?(:PG_QUERY_TYPE_MAP, false)
            begin
              ::Ractor.make_shareable(::Sequel::Postgres::PG_QUERY_TYPE_MAP)
            rescue ::Ractor::Error => e
              warn "[sequel-ractor] could not make PG_QUERY_TYPE_MAP shareable: #{e.message}"
            end
          end

          # PG::BasicTypeRegistry / other adapter-local arrays — none
          # are read during connect on the worker path in 5.104, so
          # we skip them. If user code touches them in workers, they
          # raise loudly and we extend this list.
        end

        # SQLite adapter has a type-conversion registry that's read on
        # every Database#initialize (worker context). Mark its values
        # shareable and freeze the Hash if it isn't already.
        def finalize_sqlite!
          if ::Sequel::SQLite.const_defined?(:SQLITE_TYPES, false)
            finalize_map!(::Sequel::SQLite::SQLITE_TYPES,
                          "Sequel::SQLite::SQLITE_TYPES")
          end
        end

        # MySQL adapter (mysql2 + trilogy). Lookup table for error
        # regexp matching read by the worker on connect. Pure-data,
        # already frozen; we just mark it shareable for cross-Ractor
        # reads.
        def finalize_mysql!
          if ::Sequel::MySQL.const_defined?(:MYSQL_TYPES, false)
            finalize_map!(::Sequel::MySQL::MYSQL_TYPES,
                          "Sequel::MySQL::MYSQL_TYPES")
          end
        end

        def finalize_map!(map, name)
          # Class/Module values: try to mark shareable. Rescue because
          # an unusual user-supplied class might fail — emit warning
          # rather than abort finalize.
          map.each_value do |val|
            ::Ractor.make_shareable(val)
          rescue ::Ractor::Error => e
            warn "[sequel-ractor] could not make #{val.inspect} " \
                 "shareable in #{name}: #{e.message}"
          end
          map.freeze unless map.frozen?
        end
      end
    end
  end
end

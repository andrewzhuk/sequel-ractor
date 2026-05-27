module SequelRactor
  module Patches
    # Patch `Sequel.split_symbol` so it doesn't mutate
    # `SPLIT_SYMBOL_CACHE` in worker Ractors.
    #
    # Original (in lib/sequel/core.rb):
    #
    #   SPLIT_SYMBOL_CACHE = {}
    #
    #   def split_symbol(sym)
    #     unless v = Sequel.synchronize{SPLIT_SYMBOL_CACHE[sym]}
    #       ...
    #       Sequel.synchronize{SPLIT_SYMBOL_CACHE[sym] = v}
    #     end
    #     v
    #   end
    #
    # Why this fails:
    #
    #   `SPLIT_SYMBOL_CACHE` is a mutable module-level Hash. Reading
    #   it from a non-main Ractor raises Ractor::IsolationError —
    #   even before the cache write line is reached. With our
    #   Synchronize patch making the lock a no-op in workers, the
    #   raw Hash access still fails.
    #
    # Patch strategy:
    #
    #   - During finalize!, freeze SPLIT_SYMBOL_CACHE — the contents
    #     are immutable Arrays of symbols/strings, so it's safe to
    #     mark the Hash itself shareable.
    #   - Override split_symbol to skip cache write in worker context
    #     (cache is frozen anyway, write would FrozenError).
    #
    # Perf impact in workers:
    #
    #   Cache miss on every call. split_symbol is called by Sequel's
    #   identifier handling (`db[:users][:id]`, qualified columns).
    #   On the I/O-bound hot path the cost is invisible — a few μs of
    #   string concat per query that does ~150μs of network anyway.
    module SymbolCache
      def self.install!
        ::Sequel.singleton_class.prepend(self)
      end

      def split_symbol(sym)
        # Main + cache still mutable → vanilla path.
        if ::Ractor.current == ::Ractor.main && !::Sequel::SPLIT_SYMBOL_CACHE.frozen?
          super
        else
          # Worker OR main-after-finalize: recompute every time, never
          # mutate the cache. Replicates Sequel 5.104 split_symbol
          # exactly. Tuple shape is [schema, table_or_column, alias] —
          # value lives in the MIDDLE, not the last position.
          if ::Sequel.split_symbols?
            s = sym.to_s
            case s
            when /\A((?:(?!__).)+)__((?:(?!___).)+)___(.+)\z/
              [$1.freeze, $2.freeze, $3.freeze].freeze
            when /\A((?:(?!___).)+)___(.+)\z/
              [nil, $1.freeze, $2.freeze].freeze
            when /\A((?:(?!__).)+)__(.+)\z/
              [$1.freeze, $2.freeze, nil].freeze
            else
              [nil, s.freeze, nil].freeze
            end
          else
            [nil, sym.to_s.freeze, nil].freeze
          end
        end
      end
    end

    # Freeze the cache during finalize. Extend Registries.finalize_map!
    # to also freeze SPLIT_SYMBOL_CACHE. We do it inline here to keep
    # all symbol-cache concerns in one file.
    module Registries
      class << self
        alias_method :finalize_without_symbol_cache!, :finalize!

        def finalize!
          finalize_without_symbol_cache!
          # The cache may already have entries pre-populated by main
          # during boot. Make those entries shareable, then freeze
          # the Hash itself.
          cache = ::Sequel::SPLIT_SYMBOL_CACHE
          unless cache.frozen?
            cache.each_value do |val|
              ::Ractor.make_shareable(val) rescue nil
            end
            cache.freeze
          end
        end
      end
    end
  end
end

module SequelRactor
  module Patches
    # Patch `Sequel::Database#initialize` so a Database opened inside
    # a non-main Ractor doesn't try to register itself in the global
    # `Sequel::DATABASES` array.
    #
    # Why this matters:
    #
    #   Sequel's Database#initialize does (paraphrased):
    #
    #     keep_reference = opts[:keep_reference] != false
    #     Sequel.synchronize { ::Sequel::DATABASES.push(self) } if keep_reference
    #
    #   The bare `::Sequel::DATABASES` constant read happens inside
    #   Sequel.synchronize's block, in worker context. The Array isn't
    #   shareable, so even READING the constant raises IsolationError —
    #   before our DatabasesArrayBypass would get a chance to absorb
    #   the push.
    #
    # The fix: override opts so that workers always get
    # `keep_reference: false`, which short-circuits the push entirely.
    #
    # Consequence: connections opened in workers aren't visible via
    # `Sequel::DATABASES.each` in main. This is fine — workers own
    # their connections by Ractor identity. The DATABASES registry is
    # a main-process diagnostic / shutdown helper.
    module DatabasesArray
      def self.install!
        ::Sequel::Database.prepend(self)
      end

      def initialize(opts = {}, *rest, &blk)
        if ::Ractor.current == ::Ractor.main
          super
        else
          # Force keep_reference: false in worker context so the
          # registration path is skipped entirely. We make a copy of
          # opts to avoid mutating the caller's Hash.
          worker_opts = opts.is_a?(Hash) ? opts.merge(keep_reference: false) : opts
          super(worker_opts, *rest, &blk)
        end
      end
    end
  end
end

module SequelRactor
  module Patches
    # Patch `Sequel.synchronize`.
    #
    # Original (in lib/sequel/core.rb):
    #
    #   @data_mutex = Mutex.new
    #
    #   def synchronize
    #     @data_mutex.synchronize { yield }
    #   end
    #
    # Why this fails in a worker Ractor:
    #
    #   Reading the `@data_mutex` instance variable from a non-main
    #   Ractor raises `Ractor::IsolationError` because the Mutex object
    #   is not shareable. Sequel.synchronize is on the hot path of
    #   `Database#initialize` (for the DATABASES array push), of
    #   adapter registration, and of any extension loading — so the
    #   first thing a worker does after `Sequel.connect(url)` is hit
    #   this and crash.
    #
    # Patch strategy:
    #
    #   - In MAIN Ractor: behave exactly like vanilla Sequel — take
    #     the mutex, yield, release.
    #   - In a WORKER Ractor: assume bootstrap is complete (the user
    #     has called `SequelRactor.finalize!`) and all global registries
    #     are READ-ONLY frozen Hashes. Just yield — no locking needed
    #     because there's nothing left to mutate.
    #
    # Risk window:
    #
    #   If a worker tries to mutate global state (e.g. register a new
    #   adapter, push to DATABASES), the locking absence won't matter
    #   because the mutation itself will fail on FrozenError /
    #   IsolationError. So bypassing the lock in worker context is
    #   strictly safe — it can never silently corrupt because the
    #   would-be-mutating operation can't happen anyway.
    module Synchronize
      def self.install!
        ::Sequel.singleton_class.prepend(self)
      end

      def synchronize
        if ::Ractor.current == ::Ractor.main
          super
        else
          # Worker path: no global state to lock. Just yield.
          yield
        end
      end
    end
  end
end

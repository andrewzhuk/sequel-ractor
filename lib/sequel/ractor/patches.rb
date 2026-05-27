require_relative "patches/synchronize"
require_relative "patches/registries"
require_relative "patches/databases_array"
require_relative "patches/symbol_cache"

module SequelRactor
  # Loads all monkey-patches into Sequel. Loaded at `require
  # "sequel/ractor"` time — finalisation is deferred until the user
  # calls `SequelRactor.finalize!`.
  module Patches
    # Order matters: install Synchronize first because other patches
    # call into Sequel.synchronize themselves.
    Synchronize.install!
    Registries.install!
    DatabasesArray.install!
    SymbolCache.install!
  end
end

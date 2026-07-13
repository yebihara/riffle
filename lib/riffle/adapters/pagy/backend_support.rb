# frozen_string_literal: true

require "riffle/adapters/fetch_support"

module Riffle
  module Adapters
    module Pagy
      # Cursor-fetching helpers shared by the version-specific Pagy backends
      # (legacy 8/9 and 43). The implementation now lives in the adapter-agnostic
      # Riffle::Adapters::FetchSupport (also used by the Kaminari adapter); this
      # module is kept as a stable require path / mixin name for the Pagy side.
      module BackendSupport
        include Riffle::Adapters::FetchSupport
      end
    end
  end
end

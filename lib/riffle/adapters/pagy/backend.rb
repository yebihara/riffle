# frozen_string_literal: true

require "riffle/adapters/pagy/compat"

# Loads the Pagy backend implementation matching the installed Pagy major and
# defines Riffle::Adapters::Pagy::Backend. Pagy 43 rewrote the pagination API,
# so it needs a separate implementation from the 8/9 (Pagy::Backend) era.
if Riffle::Adapters::Pagy.v43?
  require "riffle/adapters/pagy/backend_v43"
else
  require "riffle/adapters/pagy/backend_legacy"
end

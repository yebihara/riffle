# frozen_string_literal: true

# Pagy extra pattern for Riffle integration
# Usage: require 'riffle/adapters/pagy/extra'

require "riffle/adapters/pagy/compat"

if Riffle::Adapters::Pagy.supported?
  require "riffle/adapters/pagy/backend"
  require "riffle/adapters/pagy/frontend"

  # Pagy 8/9 keep a mutable DEFAULT hash; register the :riffle var there.
  # Pagy 43 froze DEFAULT (mutable options live in Pagy::OPTIONS) and the
  # adapter no longer relies on a registered var, so this is skipped.
  unless Riffle::Adapters::Pagy.v43?
    module Pagy
      # Add riffle to Pagy's DEFAULT hash if not already present
      DEFAULT[:riffle] ||= false
    end
  end

  # Include backend in controllers
  if defined?(ActionController::Base)
    ActionController::Base.include(Riffle::Adapters::Pagy::Backend)
  end

  if defined?(ActionController::API)
    ActionController::API.include(Riffle::Adapters::Pagy::Backend)
  end

  # Include frontend in views
  if defined?(ActionView::Base)
    ActionView::Base.prepend(Riffle::Adapters::Pagy::Frontend)
  end
else
  Riffle::Adapters::Pagy.warn_unsupported
end

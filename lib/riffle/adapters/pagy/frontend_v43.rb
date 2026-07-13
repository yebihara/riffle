# frozen_string_literal: true

require "riffle/adapters/pagy/frontend_support"

module Riffle
  module Adapters
    module Pagy
      # View helpers for Pagy 43+.
      #
      # There is no pagy_url_for to override on Pagy 43 — cursor_id is carried
      # into page links by the :querify option set in the backend (see
      # backend_v43.rb). Only the convenience helpers remain, and they are
      # shared with the legacy frontend via FrontendSupport.
      module Frontend
        include FrontendSupport
      end
    end
  end
end

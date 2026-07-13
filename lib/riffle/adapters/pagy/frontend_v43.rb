# frozen_string_literal: true

module Riffle
  module Adapters
    module Pagy
      # View helpers for Pagy 43+.
      #
      # There is no pagy_url_for to override on Pagy 43 — cursor_id is carried
      # into page links by the :querify option set in the backend (see
      # backend_v43.rb). Only the convenience helpers remain, and they are
      # identical across Pagy versions.
      module Frontend
        # Helper to get cursor_id from pagy instance
        def riffle_cursor_id(pagy)
          pagy.respond_to?(:riffle_cursor_id) ? pagy.riffle_cursor_id : nil
        end

        # Hidden field for forms that need to preserve cursor_id
        def riffle_cursor_field(pagy)
          cursor_id = riffle_cursor_id(pagy)
          return unless cursor_id

          cursor_param = Riffle.config.cursor_param
          hidden_field_tag(cursor_param, cursor_id)
        end
      end
    end
  end
end

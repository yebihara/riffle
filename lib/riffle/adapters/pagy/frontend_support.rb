# frozen_string_literal: true

module Riffle
  module Adapters
    module Pagy
      # View helpers shared by the version-specific Pagy frontends. These are
      # identical across Pagy versions — only pagy_url_for (legacy only)
      # differs, so it stays in frontend_legacy.rb.
      module FrontendSupport
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

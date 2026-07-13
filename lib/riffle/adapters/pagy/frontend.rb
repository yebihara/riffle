# frozen_string_literal: true

module Riffle
  module Adapters
    module Pagy
      module Frontend
        # Override pagy_url_for to include cursor_id.
        #
        # Keyword args are passed through untouched (Pagy 8/9 accept
        # absolute: and swallow unknown keywords), so this override stays
        # signature-compatible across the supported Pagy versions.
        def pagy_url_for(pagy, page, **opts)
          cursor_id = pagy.respond_to?(:riffle_cursor_id) ? pagy.riffle_cursor_id : nil

          if cursor_id
            url = super
            cursor_param = Riffle.config.cursor_param
            separator = url.include?("?") ? "&" : "?"
            url = "#{url}#{separator}#{cursor_param}=#{cursor_id}"
            opts[:html_escaped] ? url.gsub("&", "&amp;") : url
          else
            super
          end
        end

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

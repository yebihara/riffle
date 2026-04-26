# frozen_string_literal: true

module Riffle
  module Adapters
    module Kaminari
      module ViewHelpers
        # Override kaminari's paginate helper to automatically include cursor_id
        def paginate(scope, paginator_class: ::Kaminari::Helpers::Paginator, template: nil, **options)
          if scope.respond_to?(:riffle_cursor_id) && scope.riffle_cursor_id.present?
            cursor_param = Riffle.config.cursor_param
            options[:params] ||= {}
            options[:params][cursor_param] = scope.riffle_cursor_id
          end

          super(scope, paginator_class: paginator_class, template: template, **options)
        end

        # Helper to get cursor_id from a paginated scope
        def riffle_cursor_id(scope)
          scope.respond_to?(:riffle_cursor_id) ? scope.riffle_cursor_id : nil
        end

        # Hidden field for forms that need to preserve cursor_id
        def riffle_cursor_field(scope)
          cursor_id = riffle_cursor_id(scope)
          return unless cursor_id

          cursor_param = Riffle.config.cursor_param
          hidden_field_tag(cursor_param, cursor_id)
        end

        # URL helper that includes cursor_id
        def riffle_path(base_path, scope, **params)
          cursor_id = riffle_cursor_id(scope)
          if cursor_id
            cursor_param = Riffle.config.cursor_param
            params[cursor_param] = cursor_id
          end

          if base_path.is_a?(String)
            uri = URI.parse(base_path)
            existing_params = URI.decode_www_form(uri.query || "").to_h
            uri.query = URI.encode_www_form(existing_params.merge(params.stringify_keys))
            uri.to_s
          else
            url_for(base_path.merge(params))
          end
        end
      end
    end
  end
end

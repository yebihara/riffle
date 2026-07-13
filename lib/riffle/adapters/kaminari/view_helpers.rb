# frozen_string_literal: true

module Riffle
  module Adapters
    module Kaminari
      module ViewHelpers
        # Override kaminari's paginate helper to automatically carry the
        # relation's cursor into every page link, under that relation's own
        # cursor param (so two paginators on one page use different params).
        def paginate(scope, paginator_class: ::Kaminari::Helpers::Paginator, template: nil, **options)
          if scope.respond_to?(:riffle_cursor_id) && scope.riffle_cursor_id.present?
            options[:params] ||= {}
            options[:params][riffle_cursor_param(scope)] = scope.riffle_cursor_id
          end

          super(scope, paginator_class: paginator_class, template: template, **options)
        end

        # Helper to get cursor_id from a paginated scope
        def riffle_cursor_id(scope)
          scope.respond_to?(:riffle_cursor_id) ? scope.riffle_cursor_id : nil
        end

        # The cursor param name for a paginated scope (per-relation when the
        # scope carries one, else the global default).
        def riffle_cursor_param(scope)
          if scope.respond_to?(:riffle_cursor_param)
            scope.riffle_cursor_param
          else
            Riffle.config.cursor_param
          end
        end

        # Hidden field for forms that need to preserve cursor_id
        def riffle_cursor_field(scope)
          cursor_id = riffle_cursor_id(scope)
          return unless cursor_id

          hidden_field_tag(riffle_cursor_param(scope), cursor_id)
        end

        # URL helper that includes cursor_id
        def riffle_path(base_path, scope, **params)
          cursor_id = riffle_cursor_id(scope)
          params[riffle_cursor_param(scope)] = cursor_id if cursor_id

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

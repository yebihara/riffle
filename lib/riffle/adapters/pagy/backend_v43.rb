# frozen_string_literal: true

require "riffle/adapters/pagy/compat"
require "riffle/adapters/pagy/backend_support"

# Pagy::Request is not autoloaded by `require "pagy"` — it is pulled in by
# Pagy::Method. We build the request object ourselves, so require it here.
require "pagy/classes/request"

module Riffle
  module Adapters
    module Pagy
      # pagy_riffle for Pagy 43+.
      #
      # Pagy 43 is a ground-up rewrite: Pagy::Backend / Pagy::Frontend and
      # pagy_url_for are gone. Pagination is built from Pagy::Offset and a
      # Pagy::Request, and extra query params are injected through the
      # :querify option instead of overriding a URL helper.
      #
      # This mirrors Pagy::OffsetPaginator.paginate but sources the count and
      # records from the Riffle cursor/PageFetcher instead of an OFFSET query,
      # and merges a :querify lambda that carries cursor_id into page links.
      module Backend
        include BackendSupport

        # @param collection [ActiveRecord::Relation] the collection to paginate
        # @param options [Hash] Pagy options (:limit, :page, :request, :querify, ...)
        # @return [Array(Pagy::Offset, Array)] pagy instance and records
        def pagy_riffle(collection, **options)
          options = ::Pagy::OPTIONS.merge(options)
          options[:request] ||= request if respond_to?(:request)
          req = ::Pagy::Request.new(options)

          cursor_param = Riffle.config.cursor_param
          cursor_id = req.params[cursor_param.to_s]
          page = (options[:page] || req.resolve_page).to_i
          items = pagy_riffle_limit(options, req)

          store = Riffle.store
          base_scope = collection.except(:limit, :offset)

          result = riffle_fetch_result(cursor_id, base_scope, page, items, store)
          new_cursor_id = result[:cursor_id]

          options[:count] = result[:total_count]
          options[:page] = page
          options[:limit] = items
          options[:request] = req
          options[:querify] = pagy_riffle_querify(options[:querify], cursor_param, new_cursor_id)

          pagy = ::Pagy::Offset.new(**options)

          # Store cursor_id in pagy for view helpers
          pagy.define_singleton_method(:riffle_cursor_id) { new_cursor_id }

          [pagy, result[:records]]
        end

        private

        # Resolve the page size. Pagy::Request#resolve_limit only honors the
        # request param when :max_limit is set, so read the limit param
        # ourselves to keep parity with the 8/9 adapter (the limit param is
        # always respected). An explicit :limit option still wins.
        def pagy_riffle_limit(options, req)
          return options[:limit].to_i if options[:limit]

          limit_key = options[:limit_key] || ::Pagy::DEFAULT[:limit_key]
          from_params = req.params[limit_key]
          return from_params.to_i if from_params.to_s != ""

          ::Pagy::DEFAULT[:limit]
        end

        # Build the :querify lambda that injects the current cursor_id into
        # every page URL. compose_page_url already clones incoming request
        # params, so this mainly matters on the first render (before the
        # cursor_id is part of the request), and it keeps the URL correct
        # when a fresh cursor is minted after expiry. Any user-supplied
        # :querify is preserved and runs first.
        def pagy_riffle_querify(user_querify, cursor_param, cursor_id)
          key = cursor_param.to_s
          lambda do |params|
            user_querify&.call(params)
            params[key] = cursor_id if cursor_id
          end
        end
      end
    end
  end
end

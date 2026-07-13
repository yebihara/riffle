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
      # and merges a :querify lambda that carries cursor_id (and the limit,
      # when it came from the request) into page links.
      module Backend
        include BackendSupport

        # @param collection [ActiveRecord::Relation] the collection to paginate
        # @param vars [Hash] Pagy options passed positionally (8/9 calling style)
        # @param options [Hash] Pagy options passed as keywords
        # @return [Array(Pagy::Offset, Array)] pagy instance and records
        def pagy_riffle(collection, vars = {}, **options)
          # Accept a trailing positional Hash too, so callers written for the
          # 8/9 `pagy_riffle(collection, vars)` style keep working on 43.
          call_options = vars.empty? ? options : vars.merge(options)

          merged = ::Pagy::OPTIONS.merge(call_options)
          merged[:request] ||= pagy_riffle_request_source
          req = ::Pagy::Request.new(merged)

          cursor_param = Riffle.config.cursor_param
          cursor_id = pagy_riffle_param(req, cursor_param)
          page = pagy_riffle_page(call_options, merged, req)
          limit_key = (merged[:limit_key] || ::Pagy::DEFAULT[:limit_key]).to_s
          items, limit_from_param = pagy_riffle_limit(call_options, merged, req, limit_key)

          store = Riffle.store
          base_scope = collection.except(:limit, :offset)

          result = riffle_fetch_result(cursor_id, base_scope, page, items, store)
          new_cursor_id = result[:cursor_id]

          # compose_page_url drops limit_key unless :max_limit is set and clones
          # the incoming request params, so re-inject cursor_id (always) and the
          # limit (only when it came from the request — an explicit :limit option
          # is re-applied by the caller every request, matching 8/9).
          injected = { cursor_param.to_s => new_cursor_id }
          injected[limit_key] = items if limit_from_param

          user_querify = merged[:querify]
          merged[:count]   = result[:total_count]
          merged[:page]    = page
          merged[:limit]   = items
          merged[:request] = req
          merged[:querify] = pagy_riffle_querify(user_querify, injected)

          pagy = ::Pagy::Offset.new(**merged)

          # Store cursor_id in pagy for view helpers
          pagy.define_singleton_method(:riffle_cursor_id) { new_cursor_id }

          [pagy, result[:records]]
        end

        private

        # Build the source Pagy::Request needs. Prefer the controller #request;
        # fall back to a params-only hash so non-controller callers (jobs,
        # service objects) that expose #params keep working like they did on
        # Pagy 8/9. In that mode URL helpers have no base_url/path, but
        # pagination itself works.
        def pagy_riffle_request_source
          return request if respond_to?(:request) && !request.nil?
          return { params: pagy_riffle_string_params } if respond_to?(:params) && !params.nil?

          raise Riffle::ConfigurationError,
                "pagy_riffle on Pagy 43 requires the caller to provide a #request " \
                "(ActionController/Rack request) or a #params method"
        end

        def pagy_riffle_string_params
          hash = params
          hash = hash.to_unsafe_h if hash.respond_to?(:to_unsafe_h)
          hash.respond_to?(:transform_keys) ? hash.transform_keys(&:to_s) : hash.to_h
        end

        # Look up an incoming request value by key, tolerating Symbol/String
        # keys. Prefer the controller #params — it carries JSON-body params
        # that Pagy::Request#params (GET.merge(POST)) would miss — then fall
        # back to the Pagy::Request params.
        def pagy_riffle_param(req, key)
          sym = key.to_sym
          str = key.to_s

          if respond_to?(:params) && !params.nil?
            value = params[sym]
            value = params[str] if value.nil?
            return value unless value.nil?
          end

          rp = req.params
          value = rp[str]
          value = rp[sym] if value.nil?
          value
        end

        def pagy_riffle_page(call_options, merged, req)
          return call_options[:page].to_i if call_options[:page]

          page_key = merged[:page_key] || ::Pagy::DEFAULT[:page_key]
          value = pagy_riffle_param(req, page_key)
          value.to_s.empty? ? 1 : value.to_i
        end

        # Resolve the page size and report whether it came from the request.
        #
        # Precedence mirrors the 8/9 adapter: an explicit per-call :limit wins,
        # then the request param (clamped by :max_limit like Pagy's own
        # resolve_limit), then the merged/global option or Pagy default. The
        # request param is checked before the merged default so a globally
        # configured Pagy::OPTIONS[:limit] does not shadow ?limit=.
        #
        # @return [Array(Integer, Boolean)] the limit and whether it came from
        #   the request param (so it must be carried into page links)
        def pagy_riffle_limit(call_options, merged, req, limit_key)
          return [call_options[:limit].to_i, false] if call_options[:limit]

          raw = pagy_riffle_param(req, limit_key)
          param_limit = raw.to_s.to_i
          if param_limit.positive?
            max_limit = merged[:max_limit]
            clamped = max_limit ? [param_limit, max_limit.to_i].min : param_limit
            return [clamped, true]
          end

          [(merged[:limit] || ::Pagy::DEFAULT[:limit]).to_i, false]
        end

        # Build the :querify lambda that injects the current cursor_id (and,
        # when relevant, the limit) into every page URL. Any user-supplied
        # :querify is preserved and runs first.
        def pagy_riffle_querify(user_querify, injected)
          lambda do |params|
            user_querify&.call(params)
            injected.each { |k, v| params[k] = v }
          end
        end
      end
    end
  end
end

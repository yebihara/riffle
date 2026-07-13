# frozen_string_literal: true

require "riffle/adapters/pagy/compat"
require "riffle/adapters/fetch_support"

module Riffle
  module Adapters
    module Pagy
      # pagy_riffle for Pagy 8 and 9 (the Pagy::Backend era).
      module Backend
        include Riffle::Adapters::FetchSupport

        # Paginate with riffle cursor support
        # @param collection [ActiveRecord::Relation] the collection to paginate
        # @param vars [Hash] pagy options (:limit on Pagy 9, :items on Pagy 8)
        # @return [Array(Pagy, Array)] pagy instance and records
        def pagy_riffle(collection, vars = {})
          vars = pagy_riffle_get_vars(collection, vars)

          cursor_id = params[Riffle.config.cursor_param]
          store = Riffle.store
          limit_var = Riffle::Adapters::Pagy.limit_var
          page = vars[:page] || 1
          items = vars[limit_var] || Riffle::Adapters::Pagy.default_limit

          base_scope = collection.except(:limit, :offset)

          result = riffle_fetch_result(cursor_id, base_scope, page, items, store)

          pagy = ::Pagy.new(
            count: result[:total_count],
            page: page,
            limit_var => items,
            **vars.except(:count, :page, limit_var)
          )

          # Store cursor_id in pagy for view helpers
          pagy.define_singleton_method(:riffle_cursor_id) { result[:cursor_id] }

          [pagy, result[:records]]
        end

        private

        def pagy_riffle_get_vars(collection, vars)
          limit_var = Riffle::Adapters::Pagy.limit_var
          vars[:page] ||= params[:page]&.to_i || 1
          vars[limit_var] ||= params[limit_var]&.to_i if params[limit_var].present?
          vars
        end
      end
    end
  end
end

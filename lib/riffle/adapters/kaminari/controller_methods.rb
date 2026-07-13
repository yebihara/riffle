# frozen_string_literal: true

module Riffle
  module Adapters
    module Kaminari
      # Controller sugar over Riffle::Model#riffle, symmetric with pagy_riffle:
      # it reads the page and cursor params from the request and returns a
      # cursor-backed, Kaminari-paginated relation.
      #
      #   @users = riffle_page(User.order(:name))
      #   @users = riffle_page(User.order(:name), per: 20, param: :users_cursor)
      #
      # Pass a distinct +param:+ per collection to paginate several on one page
      # independently. The model must `include Riffle::Model` and respond to
      # Kaminari's +.page+.
      module ControllerMethods
        # @param relation [ActiveRecord::Relation] the (already-scoped) collection
        # @param per [Integer, nil] page size; falls back to Kaminari's default
        # @param page [Object, nil] page number; defaults to params[:page]
        # @param param [Symbol, String, nil] cursor param name (default
        #   Riffle.config.cursor_param)
        # @param store [Riffle::Store::Base, nil] override the store
        # @return [ActiveRecord::Relation]
        def riffle_page(relation, per: nil, page: nil, param: nil, store: nil)
          cursor_param = (param || Riffle.config.cursor_param).to_sym
          page ||= params[:page]
          cursor = params[cursor_param]

          scope = relation.page(page)
          scope = scope.per(per) if per
          scope.riffle(cursor: cursor, param: cursor_param, store: store)
        end
      end
    end
  end
end

# frozen_string_literal: true

module Riffle
  module Adapters
    module Pagy
      module Backend
        # Paginate with riffle cursor support
        # @param collection [ActiveRecord::Relation] the collection to paginate
        # @param vars [Hash] pagy options
        # @return [Array(Pagy, Array)] pagy instance and records
        def pagy_riffle(collection, vars = {})
          vars = pagy_riffle_get_vars(collection, vars)

          cursor_id = params[Riffle.config.cursor_param]
          store = Riffle.store
          page = vars[:page] || 1
          items = vars[:items] || ::Pagy::DEFAULT[:items]

          cursor = Riffle::Core::Cursor.find(cursor_id, store: store) if cursor_id.present?

          if cursor
            result = fetch_from_cursor(cursor, collection.klass, page, items, store)
          else
            result = fetch_with_new_cursor(collection, page, items, store)
          end

          pagy = ::Pagy.new(
            count: result[:total_count],
            page: page,
            items: items,
            **vars.except(:count, :page, :items)
          )

          # Store cursor_id in pagy for view helpers
          pagy.define_singleton_method(:riffle_cursor_id) { result[:cursor_id] }

          [pagy, result[:records]]
        end

        private

        def pagy_riffle_get_vars(collection, vars)
          vars[:page] ||= params[:page]&.to_i || 1
          vars[:items] ||= params[:items]&.to_i if params[:items].present?
          vars
        end

        def fetch_from_cursor(cursor, model_class, page, items, store)
          snapshot = Riffle::Core::Snapshot.new(cursor, store: store)
          fetcher = Riffle::Core::PageFetcher.new(snapshot: snapshot, model_class: model_class, store: store)
          result = fetcher.fetch(page: page, per_page: items)

          {
            records: result.records,
            total_count: result.total_count,
            cursor_id: result.cursor_id
          }
        end

        def fetch_with_new_cursor(collection, page, items, store)
          base_scope = collection.except(:limit, :offset)
          all_ids = base_scope.pluck(base_scope.klass.primary_key)
          total = all_ids.size

          cursor = Riffle::Core::Cursor.create(all_ids, total_count: total, store: store)

          snapshot = Riffle::Core::Snapshot.new(cursor, store: store)
          fetcher = Riffle::Core::PageFetcher.new(snapshot: snapshot, model_class: collection.klass, store: store)
          result = fetcher.fetch(page: page, per_page: items)

          {
            records: result.records,
            total_count: result.total_count,
            cursor_id: cursor.id
          }
        end
      end
    end
  end
end

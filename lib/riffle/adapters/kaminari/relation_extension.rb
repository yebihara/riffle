# frozen_string_literal: true

module Riffle
  module Adapters
    module Kaminari
      # Extension for ActiveRecord::Relation when used with Kaminari
      module RelationExtension
        attr_accessor :riffle_cursor_id, :riffle_enabled, :riffle_total_count

        def records
          if @riffle_enabled
            load_with_riffle
          else
            super
          end
        end

        def total_count(column_name = :all, _options = nil)
          if @riffle_enabled
            load_with_riffle unless @riffle_loaded
            @riffle_total_count || super
          else
            super
          end
        end

        private

        def load_with_riffle
          return @records if @riffle_loaded

          cursor_id = Riffle::Current.cursor_id
          page_num = current_page || 1
          per_page = limit_value || ::Kaminari.config.default_per_page
          store = Riffle.store

          cursor = Riffle::Core::Cursor.find(cursor_id, store: store) if cursor_id.present?

          if cursor
            @records = load_from_cursor(cursor, page_num, per_page, store)
            @riffle_cursor_id = cursor.id
          elsif cursor_id.present? && Riffle.config.on_cursor_expired == :strict
            # The caller passed a cursor_id but it no longer exists.
            # Strict mode surfaces this so the app can redirect to a fresh
            # search instead of silently creating a different snapshot.
            raise Riffle::CursorExpired, "Cursor '#{cursor_id}' has expired"
          else
            @records = load_with_new_cursor(page_num, per_page, store)
          end

          @riffle_loaded = true
          @records
        end

        def load_from_cursor(cursor, page_num, per_page, store)
          base_scope = build_base_scope
          snapshot = Riffle::Core::Snapshot.new(cursor, store: store)
          fetcher = Riffle::Core::PageFetcher.new(snapshot: snapshot, relation: base_scope, store: store)
          result = fetcher.fetch(page: page_num, per_page: per_page)

          @riffle_total_count = result.total_count
          @total_count = result.total_count  # Kaminari用
          result.records
        end

        def load_with_new_cursor(page_num, per_page, store)
          base_scope = build_base_scope
          all_ids = base_scope.pluck(klass.primary_key)
          total = all_ids.size

          cursor = Riffle::Core::Cursor.create(all_ids, total_count: total, store: store)
          @riffle_cursor_id = cursor.id
          @riffle_total_count = total
          @total_count = total  # Kaminari用

          snapshot = Riffle::Core::Snapshot.new(cursor, store: store)
          fetcher = Riffle::Core::PageFetcher.new(snapshot: snapshot, relation: base_scope, store: store)
          result = fetcher.fetch(page: page_num, per_page: per_page)

          result.records
        end

        # Returns a relation suitable for passing to PageFetcher: the original
        # scope minus pagination clauses, with @riffle_enabled cleared so that
        # the inner WHERE-by-IDs query (issued via this relation) does not
        # recurse back into load_with_riffle.
        def build_base_scope
          scope = except(:limit, :offset)
          scope.riffle_enabled = false
          scope
        end
      end
    end
  end
end

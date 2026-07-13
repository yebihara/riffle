# frozen_string_literal: true

module Riffle
  module Adapters
    # Cursor-fetching helpers shared by every adapter (Pagy 8/9, Pagy 43, and
    # Kaminari). These are the only pieces of the adapters that do not depend on
    # a pagination library's API surface, so they live in one place and are
    # mixed in by each adapter's backend/relation module.
    module FetchSupport
      private

      def fetch_from_cursor(cursor, base_scope, page, items, store)
        snapshot = Riffle::Core::Snapshot.new(cursor, store: store)
        fetcher = Riffle::Core::PageFetcher.new(snapshot: snapshot, relation: base_scope, store: store)
        result = fetcher.fetch(page: page, per_page: items)

        {
          records: result.records,
          total_count: result.total_count,
          cursor_id: result.cursor_id
        }
      end

      def fetch_with_new_cursor(base_scope, page, items, store)
        all_ids = base_scope.pluck(base_scope.klass.primary_key)
        cursor = Riffle::Core::Cursor.create(all_ids, total_count: all_ids.size, store: store)

        # Snapshot#cursor_id is @cursor.id, so the freshly created cursor's
        # id flows through the Result — no need to duplicate the fetch here.
        fetch_from_cursor(cursor, base_scope, page, items, store)
      end

      # Resolve the incoming cursor into a fetch result, applying the
      # configured :auto / :strict behavior for expired/unknown cursors.
      def riffle_fetch_result(cursor_id, base_scope, page, items, store)
        cursor = Riffle::Core::Cursor.find(cursor_id, store: store) if cursor_id.present?

        if cursor
          fetch_from_cursor(cursor, base_scope, page, items, store)
        elsif cursor_id.present? && Riffle.config.on_cursor_expired == :strict
          # The caller passed a cursor_id but it no longer exists.
          # Strict mode surfaces this so the app can redirect to a fresh
          # search instead of silently creating a different snapshot.
          raise Riffle::CursorExpired, "Cursor '#{cursor_id}' has expired"
        else
          fetch_with_new_cursor(base_scope, page, items, store)
        end
      end
    end
  end
end

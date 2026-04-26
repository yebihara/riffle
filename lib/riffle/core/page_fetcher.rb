# frozen_string_literal: true

module Riffle
  module Core
    class PageFetcher
      Result = Struct.new(:records, :total_count, :cursor_id, :page, :per_page, keyword_init: true) do
        def total_pages
          (total_count.to_f / per_page).ceil
        end

        def next_page?
          page < total_pages
        end

        def prev_page?
          page > 1
        end

        def first_page?
          page == 1
        end

        def last_page?
          page >= total_pages
        end

        def offset
          (page - 1) * per_page
        end
      end

      def initialize(snapshot:, model_class:, store: nil)
        @snapshot = snapshot
        @model_class = model_class
        @store = store || Riffle.store
      end

      # Fetch records for a specific page
      # @param page [Integer] page number (1-based)
      # @param per_page [Integer] items per page
      # @return [Result]
      def fetch(page:, per_page:)
        page = [1, page.to_i].max
        per_page = per_page.to_i
        offset = (page - 1) * per_page

        records = fetch_with_backfill(offset: offset, limit: per_page)

        Result.new(
          records: records,
          total_count: @store.total_count(@snapshot.cursor_id),
          cursor_id: @snapshot.cursor_id,
          page: page,
          per_page: per_page
        )
      end

      private

      def fetch_with_backfill(offset:, limit:)
        records = []
        current_offset = offset
        remaining = limit
        fetch_size = limit
        max_attempts = 20 # 無限ループ防止（倍々で増やすので多めに）

        max_attempts.times do
          break if remaining <= 0

          ids = @snapshot.page_ids(page: 1, per_page: fetch_size, offset: current_offset)
          break if ids.empty?

          fetched = fetch_records_by_ids(ids)
          records.concat(fetched)

          # 削除されたIDを検出
          fetched_ids = fetched.map(&:id)
          deleted_ids = ids - fetched_ids

          if deleted_ids.any?
            # キャッシュから削除されたIDを除去
            @store.remove_ids(@snapshot.cursor_id, deleted_ids)
            @store.decrement_total_count(@snapshot.cursor_id, deleted_ids.size)

            # 次回は倍の件数を取得（連続削除に対応）
            fetch_size = [fetch_size * 2, 1000].min
          else
            # 削除がなければ残り件数だけ取得
            fetch_size = remaining - fetched.size
          end

          remaining -= fetched.size
          current_offset += ids.size
        end

        records.take(limit)
      end

      def fetch_records_by_ids(ids)
        return [] if ids.empty?

        pk = @model_class.primary_key
        records = @model_class.where(pk => ids).to_a
        # Stringify on both sides: Redis store returns string IDs, Memory store
        # preserves whatever was stored. Normalizing to strings keeps the order
        # lookup correct across PK types (integer / UUID / etc).
        id_order = ids.each_with_index.to_h { |id, i| [id.to_s, i] }
        records.sort_by { |r| id_order[r.public_send(pk).to_s] || Float::INFINITY }
      end
    end
  end
end

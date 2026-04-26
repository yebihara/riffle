# frozen_string_literal: true

module Riffle
  module Store
    class Redis < Base
      IDS_SUFFIX = "ids"
      META_SUFFIX = "meta"

      def initialize(redis: nil, ttl: nil, max_ids: nil, key_prefix: nil)
        @redis = redis
        @ttl = ttl
        @max_ids = max_ids
        @key_prefix = key_prefix
      end

      def store(cursor_id, ids, total_count:)
        ids_key = ids_key(cursor_id)
        meta_key = meta_key(cursor_id)
        ttl = effective_ttl
        max_ids = effective_max_ids
        truncated = ids.size > max_ids

        if truncated
          handle_truncation!(cursor_id, ids.size, max_ids)
        end

        stored_ids = ids.take(max_ids)

        log(:info) do
          "[Riffle] STORE cursor_id=#{cursor_id} ids_count=#{stored_ids.size} total_count=#{total_count} ttl=#{ttl}s truncated=#{truncated}"
        end

        redis.multi do |multi|
          # Clear existing data
          multi.del(ids_key, meta_key)

          # Store IDs in sorted set with index as score
          if stored_ids.any?
            members = stored_ids.each_with_index.map { |id, index| [index, id] }
            multi.zadd(ids_key, members)
          end

          # Store metadata
          multi.hset(meta_key, "total_count", total_count)
          multi.hset(meta_key, "stored_count", stored_ids.size)
          multi.hset(meta_key, "truncated", truncated ? 1 : 0)

          # Set TTL
          multi.expire(ids_key, ttl)
          multi.expire(meta_key, ttl)
        end

        log(:info) { "[Riffle] ZADD #{ids_key} (#{stored_ids.size} members)" }

        true
      end

      def fetch_page(cursor_id, offset:, limit:)
        # Single-call form, kept for direct callers and the public Store API.
        # PageFetcher uses fetch_page_and_meta to avoid the extra RTT.
        fetch_page_and_meta(cursor_id, offset: offset, limit: limit)[:ids]
      end

      def fetch_page_and_meta(cursor_id, offset:, limit:)
        ids_key = ids_key(cursor_id)
        meta_key = meta_key(cursor_id)
        start_index = offset
        end_index = offset + limit - 1

        log(:info) do
          "[Riffle] PIPELINE ZRANGE #{ids_key} #{start_index} #{end_index} + HGET #{meta_key} (total_count, truncated)"
        end

        ids, total_count_str, truncated_str = redis.pipelined do |p|
          p.zrange(ids_key, start_index, end_index)
          p.hget(meta_key, "total_count")
          p.hget(meta_key, "truncated")
        end

        raise CursorExpired, "Cursor '#{cursor_id}' has expired" if total_count_str.nil?

        log(:info) do
          "[Riffle] FETCH cursor_id=#{cursor_id} offset=#{offset} limit=#{limit} fetched=#{ids.size}"
        end

        # Return ids as raw strings; ActiveRecord casts to the model's primary
        # key type at WHERE-clause time. Coercing to Integer would corrupt
        # UUIDs and other string-typed primary keys.
        {
          ids: ids,
          total_count: total_count_str.to_i,
          truncated: truncated_str.to_i == 1
        }
      end

      def total_count(cursor_id)
        meta_key = meta_key(cursor_id)
        count = redis.hget(meta_key, "total_count")

        raise CursorExpired, "Cursor '#{cursor_id}' has expired" if count.nil?

        log(:info) { "[Riffle] HGET #{meta_key} total_count=#{count}" }

        count.to_i
      end

      def stored_count(cursor_id)
        meta_key = meta_key(cursor_id)
        count = redis.hget(meta_key, "stored_count")

        raise CursorExpired, "Cursor '#{cursor_id}' has expired" if count.nil?

        count.to_i
      end

      def truncated?(cursor_id)
        flag = redis.hget(meta_key(cursor_id), "truncated")
        flag.to_i == 1
      end

      def exists?(cursor_id)
        result = redis.exists?(meta_key(cursor_id))
        log(:info) { "[Riffle] EXISTS cursor_id=#{cursor_id} result=#{result}" }
        result
      end

      def delete(cursor_id)
        log(:info) { "[Riffle] DEL cursor_id=#{cursor_id}" }
        redis.del(ids_key(cursor_id), meta_key(cursor_id)) > 0
      end

      def touch(cursor_id)
        ttl = effective_ttl
        ids_key = ids_key(cursor_id)
        meta_key = meta_key(cursor_id)

        return false unless exists?(cursor_id)

        log(:info) { "[Riffle] TOUCH cursor_id=#{cursor_id} ttl=#{ttl}s" }

        redis.multi do |multi|
          multi.expire(ids_key, ttl)
          multi.expire(meta_key, ttl)
        end

        true
      end

      def remove_ids(cursor_id, ids)
        return 0 if ids.empty?

        ids_key = ids_key(cursor_id)

        log(:info) { "[Riffle] ZREM cursor_id=#{cursor_id} ids=#{ids.inspect}" }

        removed = redis.zrem(ids_key, ids)
        removed.is_a?(Integer) ? removed : (removed ? ids.size : 0)
      end

      def decrement_total_count(cursor_id, count)
        meta_key = meta_key(cursor_id)

        new_count = redis.hincrby(meta_key, "total_count", -count)
        redis.hincrby(meta_key, "stored_count", -count)

        log(:info) { "[Riffle] DECR_COUNT cursor_id=#{cursor_id} by=#{count} new_total=#{new_count}" }

        new_count
      end

      # Single combined operation used by PageFetcher's backfill path.
      #
      # Two issues this addresses:
      #   1. Concurrent requests that both detect the same deletions would
      #      each decrement by ids.size, producing a double-decrement. Here
      #      we decrement by the *actual* ZREM return value, so a concurrent
      #      caller whose ZREM returns 0 contributes nothing to the count.
      #   2. The pair of HINCRBY calls is wrapped in MULTI so total_count
      #      and stored_count cannot fall out of sync mid-update.
      #
      # The ZREM and the HINCRBY MULTI are still two separate round trips,
      # which leaves a narrow window where a crash between them would leave
      # counts stale until cursor expiration. Closing that gap requires Lua
      # (deferred — see backlog).
      def remove_ids_and_decrement(cursor_id, ids)
        return 0 if ids.empty?

        ids_key = ids_key(cursor_id)
        meta_key = meta_key(cursor_id)

        log(:info) { "[Riffle] ZREM cursor_id=#{cursor_id} ids=#{ids.inspect}" }
        zrem_result = redis.zrem(ids_key, ids)
        removed = zrem_result.is_a?(Integer) ? zrem_result : (zrem_result ? ids.size : 0)

        if removed > 0
          redis.multi do |multi|
            multi.hincrby(meta_key, "total_count", -removed)
            multi.hincrby(meta_key, "stored_count", -removed)
          end
          log(:info) { "[Riffle] DECR_COUNT cursor_id=#{cursor_id} by=#{removed}" }
        end

        removed
      end

      private

      def redis
        @redis || Riffle.config.redis!
      end

      def effective_ttl
        @ttl || Riffle.config.ttl
      end

      def effective_max_ids
        @max_ids || Riffle.config.max_ids
      end

      def effective_key_prefix
        @key_prefix || Riffle.config.redis_key_prefix
      end

      # Wrap the cursor_id in {} so that the ids and meta keys for the same
      # cursor land in the same Redis Cluster slot (Cluster routes by the
      # substring inside the first {...} when present). Without this, MULTI
      # blocks that touch both keys fail with CROSSSLOT on Cluster.
      def ids_key(cursor_id)
        "#{effective_key_prefix}:{#{cursor_id}}:#{IDS_SUFFIX}"
      end

      def meta_key(cursor_id)
        "#{effective_key_prefix}:{#{cursor_id}}:#{META_SUFFIX}"
      end

      def log(level, &block)
        logger = Riffle.config.logger
        return unless logger

        logger.public_send(level, &block)
      end

      def handle_truncation!(cursor_id, requested, kept)
        case Riffle.config.on_max_ids_exceeded
        when :raise
          raise MaxIdsExceeded,
                "Search produced #{requested} IDs, exceeding max_ids=#{kept}. " \
                "Narrow your search or increase Riffle.config.max_ids."
        when :truncate
          log(:warn) do
            "[Riffle] IDs truncated cursor_id=#{cursor_id} requested=#{requested} kept=#{kept}"
          end
        end
      end
    end
  end
end

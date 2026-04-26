# frozen_string_literal: true

require "mock_redis"

RSpec.describe Riffle::Store::Redis do
  let(:redis) { MockRedis.new }
  let(:store) { described_class.new(redis: redis, ttl: 300, max_ids: 1000) }
  let(:cursor_id) { "test_cursor_123" }
  let(:ids) { [1, 2, 3, 4, 5, 6, 7, 8, 9, 10] }

  describe "#store" do
    it "stores IDs and returns true" do
      expect(store.store(cursor_id, ids, total_count: 100)).to be true
    end

    it "creates ids and meta keys with the configured prefix" do
      store.store(cursor_id, ids, total_count: 100)

      expect(redis.exists?("riffle:#{cursor_id}:ids")).to be true
      expect(redis.exists?("riffle:#{cursor_id}:meta")).to be true
    end

    it "stores IDs in a sorted set with index as score" do
      store.store(cursor_id, ids, total_count: 100)

      expect(redis.zrange("riffle:#{cursor_id}:ids", 0, -1)).to eq(ids.map(&:to_s))
    end

    it "stores metadata" do
      store.store(cursor_id, ids, total_count: 100)

      expect(redis.hget("riffle:#{cursor_id}:meta", "total_count")).to eq("100")
      expect(redis.hget("riffle:#{cursor_id}:meta", "stored_count")).to eq("10")
    end

    it "sets TTL on both keys" do
      store.store(cursor_id, ids, total_count: 100)

      expect(redis.ttl("riffle:#{cursor_id}:ids")).to be_between(1, 300).inclusive
      expect(redis.ttl("riffle:#{cursor_id}:meta")).to be_between(1, 300).inclusive
    end

    it "truncates IDs if exceeding max_ids" do
      small_store = described_class.new(redis: redis, ttl: 300, max_ids: 5)
      small_store.store(cursor_id, ids, total_count: 100)

      expect(small_store.stored_count(cursor_id)).to eq(5)
    end

    it "preserves total_count even when truncating" do
      small_store = described_class.new(redis: redis, ttl: 300, max_ids: 5)
      small_store.store(cursor_id, ids, total_count: 100)

      expect(small_store.total_count(cursor_id)).to eq(100)
    end

    it "overwrites existing data on subsequent store calls" do
      store.store(cursor_id, ids, total_count: 100)
      store.store(cursor_id, [99, 98], total_count: 2)

      expect(redis.zrange("riffle:#{cursor_id}:ids", 0, -1)).to eq(%w[99 98])
      expect(store.total_count(cursor_id)).to eq(2)
    end

    it "handles empty id list" do
      store.store(cursor_id, [], total_count: 0)

      expect(store.exists?(cursor_id)).to be true
      expect(store.total_count(cursor_id)).to eq(0)
      expect(store.stored_count(cursor_id)).to eq(0)
    end
  end

  describe "#fetch_page" do
    before { store.store(cursor_id, ids, total_count: 100) }

    it "returns IDs for the requested page" do
      result = store.fetch_page(cursor_id, offset: 0, limit: 3)
      expect(result.map(&:to_i)).to eq([1, 2, 3])
    end

    it "returns IDs with offset" do
      result = store.fetch_page(cursor_id, offset: 5, limit: 3)
      expect(result.map(&:to_i)).to eq([6, 7, 8])
    end

    it "returns empty array for out of range offset" do
      result = store.fetch_page(cursor_id, offset: 100, limit: 3)
      expect(result).to eq([])
    end

    it "raises CursorExpired for non-existent cursor" do
      expect {
        store.fetch_page("nonexistent", offset: 0, limit: 3)
      }.to raise_error(Riffle::CursorExpired)
    end
  end

  describe "#total_count" do
    it "returns the total count" do
      store.store(cursor_id, ids, total_count: 100)
      expect(store.total_count(cursor_id)).to eq(100)
    end

    it "raises CursorExpired for non-existent cursor" do
      expect {
        store.total_count("nonexistent")
      }.to raise_error(Riffle::CursorExpired)
    end
  end

  describe "#stored_count" do
    it "returns the stored count" do
      store.store(cursor_id, ids, total_count: 100)
      expect(store.stored_count(cursor_id)).to eq(10)
    end

    it "raises CursorExpired for non-existent cursor" do
      expect {
        store.stored_count("nonexistent")
      }.to raise_error(Riffle::CursorExpired)
    end
  end

  describe "#exists?" do
    it "returns true for existing cursor" do
      store.store(cursor_id, ids, total_count: 100)
      expect(store.exists?(cursor_id)).to be true
    end

    it "returns false for non-existent cursor" do
      expect(store.exists?("nonexistent")).to be false
    end
  end

  describe "#delete" do
    before { store.store(cursor_id, ids, total_count: 100) }

    it "deletes the cursor and returns true" do
      expect(store.delete(cursor_id)).to be true
      expect(store.exists?(cursor_id)).to be false
    end

    it "removes both ids and meta keys" do
      store.delete(cursor_id)

      expect(redis.exists?("riffle:#{cursor_id}:ids")).to be false
      expect(redis.exists?("riffle:#{cursor_id}:meta")).to be false
    end

    it "returns false for non-existent cursor" do
      expect(store.delete("nonexistent")).to be false
    end
  end

  describe "#touch" do
    before { store.store(cursor_id, ids, total_count: 100) }

    it "refreshes TTL and returns true" do
      expect(store.touch(cursor_id)).to be true
    end

    it "extends TTL on both keys" do
      short_store = described_class.new(redis: redis, ttl: 60, max_ids: 1000)
      short_store.store("short_cursor", ids, total_count: 100)

      long_store = described_class.new(redis: redis, ttl: 600, max_ids: 1000)
      long_store.touch("short_cursor")

      expect(redis.ttl("riffle:short_cursor:ids")).to be > 60
      expect(redis.ttl("riffle:short_cursor:meta")).to be > 60
    end

    it "returns false for non-existent cursor" do
      expect(store.touch("nonexistent")).to be false
    end
  end

  describe "#remove_ids" do
    before { store.store(cursor_id, ids, total_count: 100) }

    it "removes specified IDs from the sorted set" do
      removed = store.remove_ids(cursor_id, [3, 5])

      expect(removed).to eq(2)
      remaining = redis.zrange("riffle:#{cursor_id}:ids", 0, -1)
      expect(remaining.map(&:to_i)).not_to include(3)
      expect(remaining.map(&:to_i)).not_to include(5)
    end

    it "returns 0 for empty input" do
      expect(store.remove_ids(cursor_id, [])).to eq(0)
    end

    it "returns 0 when no IDs match" do
      expect(store.remove_ids(cursor_id, [999, 1000])).to eq(0)
    end
  end

  describe "#decrement_total_count" do
    before { store.store(cursor_id, ids, total_count: 100) }

    it "decrements total_count by the given amount" do
      new_count = store.decrement_total_count(cursor_id, 3)

      expect(new_count).to eq(97)
      expect(store.total_count(cursor_id)).to eq(97)
    end

    it "decrements stored_count by the same amount" do
      store.decrement_total_count(cursor_id, 3)

      expect(store.stored_count(cursor_id)).to eq(7)
    end
  end

  describe "with UUID-style string IDs" do
    let(:uuid_ids) { %w[abc-123 def-456 ghi-789] }

    before { store.store(cursor_id, uuid_ids, total_count: 3) }

    it "preserves string IDs without coercing to integer" do
      result = store.fetch_page(cursor_id, offset: 0, limit: 3)
      expect(result).to eq(uuid_ids)
    end

    it "removes string IDs intact" do
      removed = store.remove_ids(cursor_id, ["def-456"])
      expect(removed).to eq(1)

      remaining = store.fetch_page(cursor_id, offset: 0, limit: 3)
      expect(remaining).to eq(%w[abc-123 ghi-789])
    end
  end

  describe "key prefix configuration" do
    it "uses Configuration.redis_key_prefix by default" do
      Riffle.config.redis_key_prefix = "custom_prefix"
      default_store = described_class.new(redis: redis, ttl: 300, max_ids: 1000)
      default_store.store(cursor_id, ids, total_count: 100)

      expect(redis.exists?("custom_prefix:#{cursor_id}:ids")).to be true
      expect(redis.exists?("custom_prefix:#{cursor_id}:meta")).to be true
    ensure
      Riffle.config.redis_key_prefix = Riffle::Configuration::DEFAULT_REDIS_KEY_PREFIX
    end

    it "respects per-instance key_prefix override" do
      override_store = described_class.new(
        redis: redis,
        ttl: 300,
        max_ids: 1000,
        key_prefix: "other"
      )
      override_store.store(cursor_id, ids, total_count: 100)

      expect(redis.exists?("other:#{cursor_id}:ids")).to be true
      expect(redis.exists?("other:#{cursor_id}:meta")).to be true
    end
  end
end

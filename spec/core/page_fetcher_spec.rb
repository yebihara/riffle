# frozen_string_literal: true

require "ostruct"

RSpec.describe Riffle::Core::PageFetcher do
  let(:store) { Riffle::Store::Memory.new(ttl: 300, max_ids: 1000) }
  let(:ids) { [3, 1, 4, 1, 5, 9, 2, 6, 5, 3] }
  let(:cursor) { Riffle::Core::Cursor.create(ids, total_count: 10, store: store) }
  let(:snapshot) { Riffle::Core::Snapshot.new(cursor, store: store) }

  # Mock model class
  let(:model_class) do
    Class.new do
      attr_accessor :id

      def initialize(id)
        @id = id
      end

      def self.primary_key
        "id"
      end

      def self.where(conditions)
        ids = conditions[primary_key] || conditions[primary_key.to_sym]
        MockRelation.new(ids)
      end
    end
  end

  let(:fetcher) { described_class.new(snapshot: snapshot, model_class: model_class, store: store) }

  # Mock relation for where().to_a
  class MockRelation
    def initialize(ids)
      @ids = ids
    end

    def to_a
      # Simulate database returning records in arbitrary order
      @ids.uniq.sort.reverse.map { |id| OpenStruct.new(id: id) }
    end
  end

  describe "#fetch" do
    it "returns a Result struct" do
      result = fetcher.fetch(page: 1, per_page: 3)

      expect(result).to be_a(Riffle::Core::PageFetcher::Result)
      expect(result.total_count).to eq(10)
      expect(result.cursor_id).to eq(cursor.id)
      expect(result.page).to eq(1)
      expect(result.per_page).to eq(3)
    end

    it "fetches records in correct order" do
      result = fetcher.fetch(page: 1, per_page: 3)

      # IDs should be [3, 1, 4] from the first page
      expect(result.records.map(&:id)).to eq([3, 1, 4])
    end

    it "handles page 0 as page 1" do
      result = fetcher.fetch(page: 0, per_page: 3)
      expect(result.page).to eq(1)
    end

    it "handles negative page as page 1" do
      result = fetcher.fetch(page: -1, per_page: 3)
      expect(result.page).to eq(1)
    end

    it "raises ArgumentError when per_page is zero" do
      expect { fetcher.fetch(page: 1, per_page: 0) }.to raise_error(ArgumentError, /positive integer/)
    end

    it "raises ArgumentError when per_page is negative" do
      expect { fetcher.fetch(page: 1, per_page: -5) }.to raise_error(ArgumentError, /positive integer/)
    end

    it "raises ArgumentError when per_page is nil" do
      expect { fetcher.fetch(page: 1, per_page: nil) }.to raise_error(ArgumentError, /positive integer/)
    end

    it "raises ArgumentError when per_page is non-numeric string" do
      expect { fetcher.fetch(page: 1, per_page: "abc") }.to raise_error(ArgumentError, /positive integer/)
    end
  end

  describe "Result" do
    let(:result) { fetcher.fetch(page: 2, per_page: 3) }

    it "#total_pages calculates correctly" do
      expect(result.total_pages).to eq(4) # ceil(10/3)
    end

    it "#next_page? returns correctly" do
      expect(result.next_page?).to be true
    end

    it "#prev_page? returns correctly" do
      expect(result.prev_page?).to be true
    end

    it "#first_page? returns correctly" do
      expect(result.first_page?).to be false
      expect(fetcher.fetch(page: 1, per_page: 3).first_page?).to be true
    end

    it "#last_page? returns correctly" do
      expect(result.last_page?).to be false
      expect(fetcher.fetch(page: 4, per_page: 3).last_page?).to be true
    end

    it "#offset calculates correctly" do
      expect(result.offset).to eq(3) # (2-1) * 3
    end

    it "#truncated? is false when the snapshot was not capped" do
      expect(result.truncated?).to be false
    end
  end

  describe "Result#truncated? when max_ids was hit" do
    let(:tiny_store) { Riffle::Store::Memory.new(ttl: 300, max_ids: 3) }
    let(:big_ids) { (1..10).to_a }
    let(:tiny_cursor) { Riffle::Core::Cursor.create(big_ids, total_count: 10, store: tiny_store) }
    let(:tiny_snapshot) { Riffle::Core::Snapshot.new(tiny_cursor, store: tiny_store) }
    let(:tiny_fetcher) do
      described_class.new(snapshot: tiny_snapshot, model_class: model_class, store: tiny_store)
    end

    it "is true so the application can surface the cap to the user" do
      result = tiny_fetcher.fetch(page: 1, per_page: 3)
      expect(result.truncated?).to be true
    end
  end

  describe "deleted record backfill" do
    # Model class that simulates deleted records
    let(:model_with_deleted) do
      deleted_ids = [1, 4] # These IDs are "deleted"
      Class.new do
        @deleted_ids = deleted_ids

        class << self
          attr_accessor :deleted_ids
        end

        def self.primary_key
          "id"
        end

        def self.where(conditions)
          ids = conditions[primary_key] || conditions[primary_key.to_sym]
          MockRelationWithDeleted.new(ids, @deleted_ids)
        end
      end
    end

    let(:fetcher_with_deleted) do
      described_class.new(snapshot: snapshot, model_class: model_with_deleted, store: store)
    end

    it "backfills when records are deleted" do
      # IDs are [3, 1, 4, 1, 5, 9, 2, 6, 5, 3]
      # Deleted: 1, 4
      # First batch (offset=0, limit=3): [3, 1, 4]
      # After DB query: [3] (1 and 4 deleted)
      # remove_ids removes 1 and 4 from cache: [3, 5, 9, 2, 6, 5, 3]
      # Need 2 more, next batch (offset=3, limit=2): [2, 6] (from new array index 3)
      # After DB query: [2, 6] (not deleted)
      # Total: [3, 2, 6]
      result = fetcher_with_deleted.fetch(page: 1, per_page: 3)

      expect(result.records.map(&:id)).to eq([3, 2, 6])
      expect(result.records.size).to eq(3)
    end

    it "updates total_count when records are deleted" do
      fetcher_with_deleted.fetch(page: 1, per_page: 3)

      # Deleted IDs detected during fetch: 1, 4
      # Original total: 10, decremented by 2 = 8
      new_total = store.total_count(cursor.id)
      expect(new_total).to eq(8)
    end

    it "removes deleted IDs from cache" do
      fetcher_with_deleted.fetch(page: 1, per_page: 3)

      # IDs 1 and 4 should be removed from cache
      remaining_ids = store.fetch_page(cursor.id, offset: 0, limit: 20)
      expect(remaining_ids).not_to include(1)
      expect(remaining_ids).not_to include(4)
    end

    context "when store returns string IDs but records have integer PK" do
      # Simulates the Redis store path: cache holds string IDs, but the model's
      # primary key is an integer column. Comparing fetched_ids (Integer) to
      # cached ids (String) directly would always look "all deleted".
      let(:string_ids) { %w[3 1 4 1 5 9 2 6 5 3] }
      let(:string_cursor) { Riffle::Core::Cursor.create(string_ids, total_count: 10, store: store) }
      let(:string_snapshot) { Riffle::Core::Snapshot.new(string_cursor, store: store) }
      let(:string_fetcher) do
        described_class.new(snapshot: string_snapshot, model_class: model_with_deleted, store: store)
      end

      it "detects deletions correctly across String/Integer mismatch" do
        result = string_fetcher.fetch(page: 1, per_page: 3)
        # 1 and 4 are deleted; backfill should still produce 3 records.
        expect(result.records.size).to eq(3)
        expect(result.records.map(&:id)).not_to include(1, 4)
      end

      it "decrements total_count by exactly the deleted count, not the whole page" do
        string_fetcher.fetch(page: 1, per_page: 3)
        # original 10 minus deleted [1, 4] = 8
        expect(store.total_count(string_cursor.id)).to eq(8)
      end
    end
  end

  describe "with custom primary key (e.g. UUID)" do
    let(:uuid_ids) { %w[abc-123 def-456 ghi-789] }
    let(:uuid_cursor) { Riffle::Core::Cursor.create(uuid_ids, total_count: 3, store: store) }
    let(:uuid_snapshot) { Riffle::Core::Snapshot.new(uuid_cursor, store: store) }

    let(:uuid_model_class) do
      Class.new do
        attr_accessor :uuid

        def initialize(uuid)
          @uuid = uuid
        end

        def self.primary_key
          "uuid"
        end

        def self.where(conditions)
          ids = conditions[primary_key] || conditions[primary_key.to_sym]
          MockUuidRelation.new(ids)
        end
      end
    end

    let(:uuid_fetcher) do
      described_class.new(snapshot: uuid_snapshot, model_class: uuid_model_class, store: store)
    end

    it "uses primary_key to query records (not hardcoded :id)" do
      result = uuid_fetcher.fetch(page: 1, per_page: 3)
      expect(result.records.map(&:uuid)).to eq(%w[abc-123 def-456 ghi-789])
    end

    it "preserves order using primary_key value" do
      # MockUuidRelation reverses order to simulate DB returning rows out of order
      result = uuid_fetcher.fetch(page: 1, per_page: 3)
      expect(result.records.map(&:uuid)).to eq(uuid_ids) # original cache order preserved
    end
  end

  describe "scope preservation via relation:" do
    # A relation-like double that records every where(...) call so we can
    # verify the relation (not the bare model class) is used for queries.
    let(:where_calls) { [] }
    let(:scoped_relation) do
      relation_klass = Class.new do
        def initialize(model_class, calls)
          @model_class = model_class
          @calls = calls
        end

        def klass
          @model_class
        end

        def where(conditions)
          @calls << conditions
          @model_class.where(conditions)
        end
      end
      relation_klass.new(model_class, where_calls)
    end

    let(:scoped_fetcher) do
      described_class.new(snapshot: snapshot, relation: scoped_relation, store: store)
    end

    it "queries through the relation, not the bare model class" do
      scoped_fetcher.fetch(page: 1, per_page: 3)
      expect(where_calls).not_to be_empty
    end

    it "passes the primary_key when calling where" do
      scoped_fetcher.fetch(page: 1, per_page: 3)
      condition = where_calls.first
      expect(condition.keys.first.to_s).to eq("id")
    end

    it "raises ArgumentError when neither relation: nor model_class: is given" do
      expect {
        described_class.new(snapshot: snapshot, store: store)
      }.to raise_error(ArgumentError, /relation:.*model_class:/)
    end

    it "derives model_class from relation.klass" do
      fetcher = described_class.new(snapshot: snapshot, relation: scoped_relation, store: store)
      result = fetcher.fetch(page: 1, per_page: 3)
      expect(result.records.size).to eq(3)
    end
  end

  describe "with stringified IDs from store" do
    # Simulates Redis store returning string IDs (which is the actual Redis behavior)
    let(:string_ids) { %w[1 2 3] }
    let(:string_cursor) { Riffle::Core::Cursor.create(string_ids, total_count: 3, store: store) }
    let(:string_snapshot) { Riffle::Core::Snapshot.new(string_cursor, store: store) }
    let(:int_model_class) do
      Class.new do
        attr_accessor :id

        def initialize(id)
          @id = id
        end

        def self.primary_key
          "id"
        end

        def self.where(conditions)
          ids = conditions[primary_key] || conditions[primary_key.to_sym]
          # Simulate ActiveRecord casting strings to integers for integer PK
          MockRelation.new(ids.map(&:to_i))
        end
      end
    end

    let(:string_fetcher) do
      described_class.new(snapshot: string_snapshot, model_class: int_model_class, store: store)
    end

    it "matches order even when store returns strings and records have integer IDs" do
      result = string_fetcher.fetch(page: 1, per_page: 3)
      expect(result.records.map(&:id)).to eq([1, 2, 3])
    end
  end
end

# Mock relation for UUID-keyed records
class MockUuidRelation
  def initialize(ids)
    @ids = ids
  end

  def to_a
    # Simulate DB returning rows in arbitrary order
    @ids.uniq.sort.reverse.map { |id| OpenStruct.new(uuid: id) }
  end
end

# Mock relation that simulates deleted records
class MockRelationWithDeleted
  def initialize(ids, deleted_ids)
    @ids = ids
    @deleted_ids = deleted_ids
  end

  def to_a
    # Simulate ActiveRecord casting String IDs to Integer for integer PK columns.
    cast_ids = @ids.map { |id| id.is_a?(String) ? id.to_i : id }
    cast_ids.reject { |id| @deleted_ids.include?(id) }
            .uniq
            .map { |id| OpenStruct.new(id: id) }
  end
end

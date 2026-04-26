# frozen_string_literal: true

require "ostruct"
require "active_support/notifications"

RSpec.describe "ActiveSupport::Notifications integration" do
  let(:store) { Riffle::Store::Memory.new(ttl: 300, max_ids: 1000) }

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
        Struct.new(:ids) do
          def to_a
            ids.uniq.map { |id| OpenStruct.new(id: id) }
          end
        end.new(ids)
      end
    end
  end

  before { Riffle.store = store }

  def capture(event_name)
    captured = []
    sub = ActiveSupport::Notifications.subscribe(event_name) do |*args|
      e = ActiveSupport::Notifications::Event.new(*args)
      captured << { name: e.name, payload: e.payload, duration: e.duration }
    end
    yield
    captured
  ensure
    ActiveSupport::Notifications.unsubscribe(sub) if sub
  end

  describe "cursor_created.riffle" do
    it "fires when Cursor.create stores a new snapshot" do
      events = capture("cursor_created.riffle") do
        Riffle::Core::Cursor.create([1, 2, 3], total_count: 3, store: store)
      end

      expect(events.size).to eq(1)
      payload = events.first[:payload]
      expect(payload[:cursor_id]).to be_a(String)
      expect(payload[:total_count]).to eq(3)
      expect(payload[:requested_ids_count]).to eq(3)
    end
  end

  describe "page_fetched.riffle" do
    let(:cursor) { Riffle::Core::Cursor.create([1, 2, 3, 4, 5], total_count: 5, store: store) }
    let(:snapshot) { Riffle::Core::Snapshot.new(cursor, store: store) }
    let(:fetcher) { Riffle::Core::PageFetcher.new(snapshot: snapshot, model_class: model_class, store: store) }

    it "fires once per fetch with the page metadata in the payload" do
      events = capture("page_fetched.riffle") { fetcher.fetch(page: 1, per_page: 2) }

      expect(events.size).to eq(1)
      payload = events.first[:payload]
      expect(payload[:cursor_id]).to eq(cursor.id)
      expect(payload[:page]).to eq(1)
      expect(payload[:per_page]).to eq(2)
      expect(payload[:fetched_count]).to eq(2)
      expect(payload[:total_count]).to eq(5)
      expect(payload[:truncated]).to be false
    end
  end

  describe "backfill_triggered.riffle" do
    # Records that simulate deletion: id=2 is missing from DB
    let(:deleted_aware_class) do
      missing = [2]
      Class.new do
        @missing = missing
        class << self; attr_accessor :missing; end

        def self.primary_key; "id"; end

        def self.where(conditions)
          ids = conditions[primary_key] || conditions[primary_key.to_sym]
          missing = @missing
          Struct.new(:ids) do
            define_method(:to_a) do
              ids.reject { |i| missing.include?(i) }
                 .uniq
                 .map { |i| OpenStruct.new(id: i) }
            end
          end.new(ids)
        end
      end
    end

    let(:cursor) { Riffle::Core::Cursor.create([1, 2, 3, 4], total_count: 4, store: store) }
    let(:snapshot) { Riffle::Core::Snapshot.new(cursor, store: store) }
    let(:fetcher) do
      Riffle::Core::PageFetcher.new(
        snapshot: snapshot, model_class: deleted_aware_class, store: store
      )
    end

    it "fires once when a deletion is detected, with deleted/removed counts" do
      events = capture("backfill_triggered.riffle") { fetcher.fetch(page: 1, per_page: 3) }

      expect(events.size).to eq(1)
      payload = events.first[:payload]
      expect(payload[:cursor_id]).to eq(cursor.id)
      expect(payload[:deleted_ids_count]).to eq(1)
      expect(payload[:removed_count]).to eq(1)
    end

    it "does not fire when there are no deletions" do
      no_delete_class = Class.new(deleted_aware_class) do
        @missing = []
      end
      no_del_fetcher = Riffle::Core::PageFetcher.new(
        snapshot: snapshot, model_class: no_delete_class, store: store
      )

      events = capture("backfill_triggered.riffle") do
        no_del_fetcher.fetch(page: 1, per_page: 3)
      end

      expect(events).to be_empty
    end
  end
end

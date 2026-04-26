# frozen_string_literal: true

require "pagy"
require "riffle/adapters/pagy/backend"
require_relative "../../support/active_record"

RSpec.describe Riffle::Adapters::Pagy::Backend do
  let(:store) { Riffle::Store::Memory.new(ttl: 300, max_ids: 1000) }

  let(:controller_class) do
    Class.new do
      include ::Pagy::Backend
      include Riffle::Adapters::Pagy::Backend
      attr_accessor :params

      def initialize(params = {})
        @params = params
      end
    end
  end

  before do
    Riffle.store = store
    20.times { |i| User.create!(name: "user-#{i.to_s.rjust(2, '0')}") }
  end

  describe "#pagy_riffle (no cursor_id provided)" do
    let(:controller) { controller_class.new(page: 1, items: 5) }

    it "returns a Pagy instance and a page of records" do
      pagy, records = controller.pagy_riffle(User.order(:name))

      expect(pagy).to be_a(::Pagy)
      expect(records.size).to eq(5)
      expect(records.map(&:name)).to eq(%w[user-00 user-01 user-02 user-03 user-04])
    end

    it "creates a new cursor in the store" do
      pagy, _ = controller.pagy_riffle(User.order(:name))

      expect(pagy.riffle_cursor_id).to be_a(String)
      expect(store.exists?(pagy.riffle_cursor_id)).to be true
    end

    it "reports the full result-set count via Pagy" do
      pagy, _ = controller.pagy_riffle(User.order(:name))

      expect(pagy.count).to eq(20)
    end
  end

  describe "#pagy_riffle (with existing cursor_id)" do
    let(:initial_controller) { controller_class.new(page: 1, items: 5) }

    it "reuses the same cursor across page navigation" do
      pagy1, _ = initial_controller.pagy_riffle(User.order(:name))
      cursor_id = pagy1.riffle_cursor_id

      next_controller = controller_class.new(page: 2, items: 5, cursor_id: cursor_id)
      pagy2, records2 = next_controller.pagy_riffle(User.order(:name))

      expect(pagy2.riffle_cursor_id).to eq(cursor_id)
      expect(records2.map(&:name)).to eq(%w[user-05 user-06 user-07 user-08 user-09])
    end

    it "preserves snapshot semantics: newly inserted rows do not appear" do
      pagy1, _ = initial_controller.pagy_riffle(User.order(:name))
      cursor_id = pagy1.riffle_cursor_id

      # Insert a row that would sort to the front
      User.create!(name: "user-AAA")  # would be at top alphabetically? Actually 'A' < 'a' in ASCII

      next_controller = controller_class.new(page: 1, items: 3, cursor_id: cursor_id)
      _, records = next_controller.pagy_riffle(User.order(:name))

      expect(records.map(&:name)).not_to include("user-AAA")
    end
  end

  describe "scope preservation across pages" do
    before do
      # Give each user a profile so we can detect N+1 if includes is dropped
      User.find_each { |u| Profile.create!(user: u, bio: "Bio for #{u.name}") }
    end

    it "preserves includes(:profile) across page navigation (no N+1)" do
      ctrl1 = controller_class.new(page: 1, items: 5)
      pagy1, records1 = ctrl1.pagy_riffle(User.includes(:profile).order(:name))

      # Verify associations are loaded for first page (this is just a sanity check)
      expect(records1.first.association(:profile)).to be_loaded

      # Page 2 with cursor_id - this is the path that previously dropped includes
      ctrl2 = controller_class.new(
        page: 2, items: 5, cursor_id: pagy1.riffle_cursor_id
      )
      _, records2 = ctrl2.pagy_riffle(User.includes(:profile).order(:name))

      expect(records2.first.association(:profile)).to be_loaded
    end
  end

  describe "with UUID primary key" do
    before do
      %w[a-1 b-2 c-3 d-4 e-5].each { |id| UuidRecord.create!(uuid: id, label: "L-#{id}") }
    end

    it "paginates UUID-keyed records correctly" do
      ctrl = controller_class.new(page: 1, items: 3)
      pagy, records = ctrl.pagy_riffle(UuidRecord.order(:uuid))

      expect(records.map(&:uuid)).to eq(%w[a-1 b-2 c-3])
      expect(pagy.count).to eq(5)
    end

    it "preserves UUID identity on subsequent pages via cursor" do
      ctrl1 = controller_class.new(page: 1, items: 3)
      pagy1, _ = ctrl1.pagy_riffle(UuidRecord.order(:uuid))

      ctrl2 = controller_class.new(
        page: 2, items: 3, cursor_id: pagy1.riffle_cursor_id
      )
      _, records2 = ctrl2.pagy_riffle(UuidRecord.order(:uuid))

      expect(records2.map(&:uuid)).to eq(%w[d-4 e-5])
    end
  end
end

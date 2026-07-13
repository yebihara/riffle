# frozen_string_literal: true

require "pagy"
require "riffle/adapters/pagy/backend"
require_relative "../../support/active_record"

RSpec.describe Riffle::Adapters::Pagy::Backend do
  let(:store) { Riffle::Store::Memory.new(ttl: 300, max_ids: 1000) }
  # :limit on Pagy 9+, :items on Pagy 8 — keeps this spec green on both.
  let(:limit_key) { Riffle::Adapters::Pagy.limit_var }

  # The controller stub differs by Pagy major. On 8/9 pagy_riffle reads the
  # controller's #params; on 43 it sources page/limit/cursor_id from a
  # Pagy::Request built from #request (a plain hash is accepted, string keys).
  let(:controller_class) do
    if Riffle::Adapters::Pagy.v43?
      Class.new do
        include Riffle::Adapters::Pagy::Backend
        attr_accessor :params

        def initialize(params = {})
          @params = params
        end

        # Pagy 43 accepts a plain Hash request (base_url/path/params).
        def request
          {
            base_url: "http://example.com",
            path: "/users",
            params: @params.transform_keys(&:to_s)
          }
        end
      end
    else
      Class.new do
        include ::Pagy::Backend
        include Riffle::Adapters::Pagy::Backend
        attr_accessor :params

        def initialize(params = {})
          @params = params
        end
      end
    end
  end

  before do
    Riffle.store = store
    20.times { |i| User.create!(name: "user-#{i.to_s.rjust(2, '0')}") }
  end

  describe "#pagy_riffle (no cursor_id provided)" do
    let(:controller) { controller_class.new(page: 1, limit_key => 5) }

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

  describe "#pagy_riffle when cursor_id is expired/unknown" do
    let(:controller) { controller_class.new(page: 1, limit_key => 5, cursor_id: "never-existed") }

    it "creates a new cursor under :auto (default)" do
      pagy, _ = controller.pagy_riffle(User.order(:name))
      expect(pagy.riffle_cursor_id).to be_a(String)
      expect(pagy.riffle_cursor_id).not_to eq("never-existed")
    end

    it "raises Riffle::CursorExpired under :strict" do
      Riffle.config.on_cursor_expired = :strict
      expect {
        controller.pagy_riffle(User.order(:name))
      }.to raise_error(Riffle::CursorExpired, /never-existed/)
    ensure
      Riffle.config.on_cursor_expired = :auto
    end

    it "still creates a fresh cursor under :strict when no cursor_id is given" do
      Riffle.config.on_cursor_expired = :strict
      ctrl = controller_class.new(page: 1, limit_key => 5)  # no cursor_id at all
      expect {
        ctrl.pagy_riffle(User.order(:name))
      }.not_to raise_error
    ensure
      Riffle.config.on_cursor_expired = :auto
    end
  end

  describe "#pagy_riffle (with existing cursor_id)" do
    let(:initial_controller) { controller_class.new(page: 1, limit_key => 5) }

    it "reuses the same cursor across page navigation" do
      pagy1, _ = initial_controller.pagy_riffle(User.order(:name))
      cursor_id = pagy1.riffle_cursor_id

      next_controller = controller_class.new(page: 2, limit_key => 5, cursor_id: cursor_id)
      pagy2, records2 = next_controller.pagy_riffle(User.order(:name))

      expect(pagy2.riffle_cursor_id).to eq(cursor_id)
      expect(records2.map(&:name)).to eq(%w[user-05 user-06 user-07 user-08 user-09])
    end

    it "preserves snapshot semantics: newly inserted rows do not appear" do
      pagy1, _ = initial_controller.pagy_riffle(User.order(:name))
      cursor_id = pagy1.riffle_cursor_id

      # Insert a row that would sort to the front
      User.create!(name: "user-AAA")  # would be at top alphabetically? Actually 'A' < 'a' in ASCII

      next_controller = controller_class.new(page: 1, limit_key => 3, cursor_id: cursor_id)
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
      ctrl1 = controller_class.new(page: 1, limit_key => 5)
      pagy1, records1 = ctrl1.pagy_riffle(User.includes(:profile).order(:name))

      # Verify associations are loaded for first page (this is just a sanity check)
      expect(records1.first.association(:profile)).to be_loaded

      # Page 2 with cursor_id - this is the path that previously dropped includes
      ctrl2 = controller_class.new(
        page: 2, limit_key => 5, cursor_id: pagy1.riffle_cursor_id
      )
      _, records2 = ctrl2.pagy_riffle(User.includes(:profile).order(:name))

      expect(records2.first.association(:profile)).to be_loaded
    end
  end

  describe "cursor_id propagation into page links (Pagy 43)", if: Riffle::Adapters::Pagy.v43? do
    it "injects cursor_id into page_url via the :querify option" do
      ctrl = controller_class.new(page: 1, limit_key => 5)
      pagy, _ = ctrl.pagy_riffle(User.order(:name))

      url = pagy.page_url(2)
      expect(url).to include("cursor_id=#{pagy.riffle_cursor_id}")
      expect(url).to include("page=2")
    end

    it "preserves a user-supplied :querify lambda" do
      ctrl = controller_class.new(page: 1, limit_key => 5)
      pagy, _ = ctrl.pagy_riffle(
        User.order(:name),
        querify: ->(params) { params["extra"] = "kept" }
      )

      url = pagy.page_url(2)
      expect(url).to include("extra=kept")
      expect(url).to include("cursor_id=#{pagy.riffle_cursor_id}")
    end
  end

  describe "with UUID primary key" do
    before do
      %w[a-1 b-2 c-3 d-4 e-5].each { |id| UuidRecord.create!(uuid: id, label: "L-#{id}") }
    end

    it "paginates UUID-keyed records correctly" do
      ctrl = controller_class.new(page: 1, limit_key => 3)
      pagy, records = ctrl.pagy_riffle(UuidRecord.order(:uuid))

      expect(records.map(&:uuid)).to eq(%w[a-1 b-2 c-3])
      expect(pagy.count).to eq(5)
    end

    it "preserves UUID identity on subsequent pages via cursor" do
      ctrl1 = controller_class.new(page: 1, limit_key => 3)
      pagy1, _ = ctrl1.pagy_riffle(UuidRecord.order(:uuid))

      ctrl2 = controller_class.new(
        page: 2, limit_key => 3, cursor_id: pagy1.riffle_cursor_id
      )
      _, records2 = ctrl2.pagy_riffle(UuidRecord.order(:uuid))

      expect(records2.map(&:uuid)).to eq(%w[d-4 e-5])
    end
  end
end

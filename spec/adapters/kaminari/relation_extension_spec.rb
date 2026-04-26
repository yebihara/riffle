# frozen_string_literal: true

require_relative "../../support/active_record"
require_relative "../../support/kaminari"

RSpec.describe Riffle::Adapters::Kaminari::RelationExtension do
  let(:store) { Riffle::Store::Memory.new(ttl: 300, max_ids: 1000) }

  before do
    Riffle.store = store
    20.times { |i| User.create!(name: "user-#{i.to_s.rjust(2, '0')}") }
  end

  context "when Riffle::Current is not enabled" do
    it "behaves like ordinary Kaminari pagination (no cursor created)" do
      Riffle::Current.enabled = false
      relation = User.order(:name).page(1).per(5)
      expect(relation.records.size).to eq(5)
      expect(relation.riffle_cursor_id).to be_nil
    end
  end

  context "when Riffle::Current.enabled = true (initial request, no cursor_id)" do
    before do
      Riffle::Current.enabled = true
      Riffle::Current.cursor_id = nil
    end

    it "materializes a new cursor and returns the first page" do
      relation = User.order(:name).page(1).per(5)
      records = relation.records

      expect(records.size).to eq(5)
      expect(records.map(&:name)).to eq(%w[user-00 user-01 user-02 user-03 user-04])
      expect(relation.riffle_cursor_id).to be_a(String)
      expect(store.exists?(relation.riffle_cursor_id)).to be true
    end

    it "reports the full result-set count via total_count" do
      relation = User.order(:name).page(1).per(5)
      relation.records # force load
      expect(relation.total_count).to eq(20)
    end
  end

  context "when cursor_id is expired/unknown" do
    before do
      Riffle::Current.enabled = true
      Riffle::Current.cursor_id = "never-existed"
    end

    it "creates a new cursor under :auto (default)" do
      relation = User.order(:name).page(1).per(5)
      relation.records
      expect(relation.riffle_cursor_id).to be_a(String)
      expect(relation.riffle_cursor_id).not_to eq("never-existed")
    end

    it "raises Riffle::CursorExpired under :strict" do
      Riffle.config.on_cursor_expired = :strict
      expect {
        User.order(:name).page(1).per(5).records
      }.to raise_error(Riffle::CursorExpired, /never-existed/)
    ensure
      Riffle.config.on_cursor_expired = :auto
    end
  end

  context "when reusing an existing cursor_id" do
    let(:initial_relation) do
      Riffle::Current.enabled = true
      User.order(:name).page(1).per(5).tap(&:records)
    end

    it "returns subsequent pages from the same snapshot" do
      cursor_id = initial_relation.riffle_cursor_id

      Riffle::Current.cursor_id = cursor_id
      page2 = User.order(:name).page(2).per(5)
      records = page2.records

      expect(page2.riffle_cursor_id).to eq(cursor_id)
      expect(records.map(&:name)).to eq(%w[user-05 user-06 user-07 user-08 user-09])
    end

    it "preserves snapshot semantics: rows added after cursor creation do not appear" do
      cursor_id = initial_relation.riffle_cursor_id
      User.create!(name: "user-AAA") # would sort first if a fresh query were issued

      Riffle::Current.cursor_id = cursor_id
      page1_again = User.order(:name).page(1).per(5)
      records = page1_again.records

      expect(records.map(&:name)).not_to include("user-AAA")
    end

    it "preserves includes(:profile) across page navigation (no N+1)" do
      User.find_each { |u| Profile.create!(user: u, bio: "Bio for #{u.name}") }

      Riffle::Current.enabled = true
      Riffle::Current.cursor_id = nil
      page1 = User.includes(:profile).order(:name).page(1).per(5)
      page1.records

      Riffle::Current.cursor_id = page1.riffle_cursor_id
      page2 = User.includes(:profile).order(:name).page(2).per(5)
      records2 = page2.records

      expect(records2.first.association(:profile)).to be_loaded
    end
  end

  context "with UUID primary key" do
    before do
      Riffle::Current.enabled = true
      Riffle::Current.cursor_id = nil
      %w[a-1 b-2 c-3 d-4 e-5].each { |id| UuidRecord.create!(uuid: id, label: "L-#{id}") }
    end

    it "paginates UUID-keyed records correctly" do
      relation = UuidRecord.order(:uuid).page(1).per(3)
      records = relation.records

      expect(records.map(&:uuid)).to eq(%w[a-1 b-2 c-3])
      expect(relation.total_count).to eq(5)
    end

    it "reuses cursor across pages with UUID PKs intact" do
      page1 = UuidRecord.order(:uuid).page(1).per(3)
      page1.records

      Riffle::Current.cursor_id = page1.riffle_cursor_id
      page2 = UuidRecord.order(:uuid).page(2).per(3)
      records = page2.records

      expect(records.map(&:uuid)).to eq(%w[d-4 e-5])
    end
  end
end

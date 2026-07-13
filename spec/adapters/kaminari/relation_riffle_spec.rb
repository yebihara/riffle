# frozen_string_literal: true

require_relative "../../support/active_record"
require_relative "../../support/kaminari"

RSpec.describe Riffle::Adapters::Kaminari::RelationRiffle do
  let(:store) { Riffle::Store::Memory.new(ttl: 300, max_ids: 1000) }

  before do
    Riffle.store = store
    20.times { |i| User.create!(name: "user-#{i.to_s.rjust(2, '0')}") }
  end

  describe "opting in via Riffle::Model#riffle" do
    it "adds the class-level scope and works on relations (chained last)" do
      relation = User.order(:name).page(1).per(5).riffle
      expect(relation).to respond_to(:riffle_cursor_id)
      expect(relation).to respond_to(:riffle_cursor_param)
    end
  end

  context "initial request (no cursor)" do
    it "materializes a new cursor and returns the first page" do
      relation = User.order(:name).page(1).per(5).riffle(cursor: nil)
      records = relation.records

      expect(records.size).to eq(5)
      expect(records.map(&:name)).to eq(%w[user-00 user-01 user-02 user-03 user-04])
      expect(relation.riffle_cursor_id).to be_a(String)
      expect(store.exists?(relation.riffle_cursor_id)).to be true
    end

    it "reports the full result-set count via total_count" do
      relation = User.order(:name).page(1).per(5).riffle
      expect(relation.total_count).to eq(20)
    end

    it "computes total_pages from the snapshot count" do
      relation = User.order(:name).page(1).per(5).riffle
      expect(relation.total_pages).to eq(4)
    end

    it "creates exactly one cursor per page render (no recursion / double create)" do
      relation = User.order(:name).page(1).per(5).riffle
      relation.total_count # forces load via total_pages path
      relation.records     # already loaded; must not create another cursor
      expect(store.raw_data.size).to eq(1)
    end
  end

  context "when cursor_id is expired/unknown" do
    it "creates a new cursor under :auto (default)" do
      relation = User.order(:name).page(1).per(5).riffle(cursor: "never-existed")
      relation.records
      expect(relation.riffle_cursor_id).to be_a(String)
      expect(relation.riffle_cursor_id).not_to eq("never-existed")
    end

    it "raises Riffle::CursorExpired under :strict" do
      Riffle.config.on_cursor_expired = :strict
      expect {
        User.order(:name).page(1).per(5).riffle(cursor: "never-existed").records
      }.to raise_error(Riffle::CursorExpired, /never-existed/)
    ensure
      Riffle.config.on_cursor_expired = :auto
    end
  end

  context "reusing an existing cursor_id" do
    def seed_cursor
      User.order(:name).page(1).per(5).riffle(cursor: nil).tap(&:records).riffle_cursor_id
    end

    it "returns subsequent pages from the same snapshot" do
      cursor_id = seed_cursor

      page2 = User.order(:name).page(2).per(5).riffle(cursor: cursor_id)
      records = page2.records

      expect(page2.riffle_cursor_id).to eq(cursor_id)
      expect(records.map(&:name)).to eq(%w[user-05 user-06 user-07 user-08 user-09])
    end

    it "preserves snapshot semantics: rows added after cursor creation do not appear" do
      cursor_id = seed_cursor
      User.create!(name: "user-AAA") # would sort first if a fresh query were issued

      page1_again = User.order(:name).page(1).per(5).riffle(cursor: cursor_id)
      expect(page1_again.records.map(&:name)).not_to include("user-AAA")
    end

    it "preserves includes(:profile) across page navigation (no N+1)" do
      User.find_each { |u| Profile.create!(user: u, bio: "Bio for #{u.name}") }

      page1 = User.includes(:profile).order(:name).page(1).per(5).riffle(cursor: nil)
      page1.records

      page2 = User.includes(:profile).order(:name).page(2).per(5).riffle(cursor: page1.riffle_cursor_id)
      records2 = page2.records

      expect(records2.first.association(:profile)).to be_loaded
    end
  end

  context "chaining order" do
    it "works with .riffle after .where and .order" do
      relation = User.where("name > ?", "user-04").order(:name).page(1).per(3).riffle
      expect(relation.records.map(&:name)).to eq(%w[user-05 user-06 user-07])
      expect(relation.total_count).to eq(15)
    end

    it "works with .per applied after .riffle" do
      # limit/offset spawn+clone preserve the module order, so riffle still wins.
      relation = User.order(:name).page(1).riffle.per(5)
      expect(relation.total_count).to eq(20)
      expect(relation.method(:total_count).owner).to eq(described_class)
      expect(relation.records.map(&:name)).to eq(%w[user-00 user-01 user-02 user-03 user-04])
    end

    it "raises a clear error at .page time when .riffle is applied first (misuse)" do
      # Kaminari mixes total_count in at .page time; applied before .page, riffle
      # loses the resolution and would silently report the live count — even on
      # count-only paths that never read records. The extending override fails
      # at the .page call itself, before any read.
      expect { User.order(:name).riffle(cursor: nil).page(1) }.to raise_error(
        Riffle::ConfigurationError, /chain \.riffle AFTER \.page/
      )
    end

    it "allows .page on a correctly-ordered riffled relation (page navigation)" do
      first = User.order(:name).page(1).per(5).riffle(cursor: nil)
      first.records
      # Kaminari's .page resets the limit to default_per_page, so .per must be
      # re-chained — same as with a plain Kaminari relation.
      second = first.page(2).per(5)

      expect(second.records.map(&:name)).to eq(%w[user-05 user-06 user-07 user-08 user-09])
    end
  end

  context "relations derived from a loaded riffle relation" do
    # Memoized results must not leak through clone/spawn: a derived relation
    # re-queries against the (cloned) cursor state instead of returning the
    # parent's stale page.
    it "re-queries when conditions are added after load" do
      parent = User.order(:name).page(1).per(5).riffle(cursor: nil)
      expect(parent.records.size).to eq(5)

      derived = parent.where("name LIKE ?", "zzz%") # matches nothing
      expect(derived.records).to eq([])
    end

    it "honors a page-size change after load" do
      parent = User.order(:name).page(1).per(5).riffle(cursor: nil)
      parent.records

      resized = parent.per(3)
      expect(resized.records.map(&:name)).to eq(%w[user-00 user-01 user-02])
    end

    it "stays on the same snapshot across derivation" do
      parent = User.order(:name).page(1).per(5).riffle(cursor: nil)
      parent.records
      cursor_id = parent.riffle_cursor_id

      resized = parent.per(3)
      resized.records
      expect(resized.riffle_cursor_id).to eq(cursor_id)
    end
  end

  context "non-controller context (Layer 1, no request/params)" do
    it "paginates with an explicit cursor and no controller involved" do
      first = User.order(:name).page(1).per(4).riffle(cursor: nil)
      first.records
      cursor_id = first.riffle_cursor_id

      second = User.order(:name).page(2).per(4).riffle(cursor: cursor_id)
      expect(second.records.map(&:name)).to eq(%w[user-04 user-05 user-06 user-07])
    end

    it "defaults to page 1 / Kaminari default_per_page when .page is omitted" do
      relation = User.order(:name).riffle(cursor: nil)
      expect(relation.records.map(&:name).first).to eq("user-00")
      expect(relation.total_count).to eq(20)
    end
  end

  context "per-relation store override" do
    it "uses the store passed to .riffle" do
      other = Riffle::Store::Memory.new(ttl: 300, max_ids: 1000)
      relation = User.order(:name).page(1).per(5).riffle(cursor: nil, store: other)
      relation.records

      expect(other.exists?(relation.riffle_cursor_id)).to be true
      expect(store.raw_data).to be_empty
    end
  end

  context "with UUID primary key" do
    before do
      %w[a-1 b-2 c-3 d-4 e-5].each { |id| UuidRecord.create!(uuid: id, label: "L-#{id}") }
    end

    it "paginates UUID-keyed records correctly" do
      relation = UuidRecord.order(:uuid).page(1).per(3).riffle(cursor: nil)
      expect(relation.records.map(&:uuid)).to eq(%w[a-1 b-2 c-3])
      expect(relation.total_count).to eq(5)
    end

    it "reuses cursor across pages with UUID PKs intact" do
      page1 = UuidRecord.order(:uuid).page(1).per(3).riffle(cursor: nil)
      page1.records

      page2 = UuidRecord.order(:uuid).page(2).per(3).riffle(cursor: page1.riffle_cursor_id)
      expect(page2.records.map(&:uuid)).to eq(%w[d-4 e-5])
    end
  end

  context "multi-pagination (the motivating regression)" do
    before do
      20.times { |i| Post.create!(title: "post-#{i.to_s.rjust(2, '0')}") }
    end

    it "keeps two collections' snapshots independent via distinct params" do
      # Two paginated collections rendered in one 'action', distinct cursor params.
      users = User.order(:name).page(1).per(5).riffle(cursor: nil, param: :users_cursor)
      posts = Post.order(:title).page(1).per(5).riffle(cursor: nil, param: :posts_cursor)
      users.records
      posts.records

      users_cursor = users.riffle_cursor_id
      posts_cursor = posts.riffle_cursor_id
      expect(users_cursor).not_to eq(posts_cursor)
      expect(users.riffle_cursor_param).to eq(:users_cursor)
      expect(posts.riffle_cursor_param).to eq(:posts_cursor)

      users_ids_before = store.raw_data[users_cursor][:ids].dup

      # Navigate ONLY posts to page 2, resuming the posts snapshot.
      posts_p2 = Post.order(:title).page(2).per(5).riffle(cursor: posts_cursor, param: :posts_cursor)
      records = posts_p2.records

      # Posts advanced correctly...
      expect(records.map(&:title)).to eq(%w[post-05 post-06 post-07 post-08 post-09])
      expect(posts_p2.riffle_cursor_id).to eq(posts_cursor)

      # ...and the users snapshot is completely untouched (membership + rendering).
      expect(store.raw_data[users_cursor][:ids]).to eq(users_ids_before)

      users_again = User.order(:name).page(1).per(5).riffle(cursor: users_cursor, param: :users_cursor)
      expect(users_again.records.map(&:name)).to eq(%w[user-00 user-01 user-02 user-03 user-04])
    end
  end
end

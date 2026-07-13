# frozen_string_literal: true

require_relative "../../support/active_record"
require_relative "../../support/kaminari"
require "riffle/adapters/kaminari/controller_methods"

RSpec.describe Riffle::Adapters::Kaminari::ControllerMethods do
  let(:store) { Riffle::Store::Memory.new(ttl: 300, max_ids: 1000) }

  let(:controller_class) do
    Class.new do
      include Riffle::Adapters::Kaminari::ControllerMethods
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

  describe "#riffle_page" do
    it "reads params[:page] and the default cursor param" do
      controller = controller_class.new(page: "2")
      relation = controller.riffle_page(User.order(:name), per: 5)

      expect(relation.current_page).to eq(2)
      expect(relation.records.map(&:name)).to eq(%w[user-05 user-06 user-07 user-08 user-09])
      expect(relation.riffle_cursor_param).to eq(:cursor_id)
    end

    it "resumes an existing snapshot from the cursor param" do
      seed = controller_class.new(page: "1").riffle_page(User.order(:name), per: 5)
      seed.records
      cursor_id = seed.riffle_cursor_id

      controller = controller_class.new(page: "2", cursor_id: cursor_id)
      relation = controller.riffle_page(User.order(:name), per: 5)

      expect(relation.riffle_cursor_id).to eq(cursor_id)
      expect(relation.records.map(&:name)).to eq(%w[user-05 user-06 user-07 user-08 user-09])
      expect(store.raw_data.size).to eq(1)
    end

    it "honors a per-collection :param name" do
      controller = controller_class.new(page: "1", users_cursor: nil)
      relation = controller.riffle_page(User.order(:name), per: 5, param: :users_cursor)
      relation.records

      expect(relation.riffle_cursor_param).to eq(:users_cursor)
    end

    it "keeps two collections independent when navigated separately" do
      Post.delete_all
      20.times { |i| Post.create!(title: "post-#{i.to_s.rjust(2, '0')}") }

      c1 = controller_class.new(page: "1")
      users = c1.riffle_page(User.order(:name), per: 5, param: :users_cursor)
      posts = c1.riffle_page(Post.order(:title), per: 5, param: :posts_cursor)
      users.records
      posts.records
      users_cursor = users.riffle_cursor_id
      posts_cursor = posts.riffle_cursor_id
      users_ids_before = store.raw_data[users_cursor][:ids].dup

      # Second request: advance only posts, echoing both cursors as a browser would.
      c2 = controller_class.new(page: "2", users_cursor: users_cursor, posts_cursor: posts_cursor)
      posts_p2 = c2.riffle_page(Post.order(:title), per: 5, param: :posts_cursor)
      posts_p2.records

      expect(posts_p2.riffle_cursor_id).to eq(posts_cursor)
      expect(store.raw_data[users_cursor][:ids]).to eq(users_ids_before)
      expect(store.raw_data.size).to eq(2)
    end

    it "defaults page to 1 when params[:page] is absent" do
      controller = controller_class.new({})
      relation = controller.riffle_page(User.order(:name), per: 5)
      expect(relation.current_page).to eq(1)
    end
  end
end

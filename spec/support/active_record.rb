# frozen_string_literal: true

require "active_record"
require "logger"

ActiveRecord::Base.logger = Logger.new(IO::NULL)
ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")

ActiveRecord::Schema.define do
  self.verbose = false

  create_table :users, force: true do |t|
    t.string :name
    t.string :email
    t.timestamps
  end

  create_table :profiles, force: true do |t|
    t.references :user
    t.string :bio
  end

  # Second model, used by the multi-pagination specs
  create_table :posts, force: true do |t|
    t.string :title
    t.timestamps
  end

  # UUID-keyed table for primary-key tests
  create_table :uuid_records, primary_key: :uuid, id: :string, force: true do |t|
    t.string :label
  end
end

class User < ActiveRecord::Base
  has_one :profile
end

class Profile < ActiveRecord::Base
  belongs_to :user
end

class Post < ActiveRecord::Base
end

class UuidRecord < ActiveRecord::Base
  self.primary_key = :uuid
end

module ActiveRecordHelpers
  def reset_db!
    User.delete_all
    Profile.delete_all
    UuidRecord.delete_all
    Post.delete_all
  end
end

RSpec.configure do |config|
  config.include ActiveRecordHelpers
  config.before(:each) { reset_db! }
end

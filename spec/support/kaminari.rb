# frozen_string_literal: true

require "kaminari"
require "kaminari/activerecord"
require "riffle/model"

# Opt the test models into the Kaminari adapter the same way an app would:
# a single `include Riffle::Model`, no global ActiveRecord::Relation patches.
User.include(Riffle::Model)
UuidRecord.include(Riffle::Model)
Post.include(Riffle::Model)

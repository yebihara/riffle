# frozen_string_literal: true

require "kaminari"
require "kaminari/activerecord"
require "riffle/adapters/kaminari/relation_extension"
require "riffle/adapters/kaminari/hooks"

ActiveRecord::Relation.prepend(Riffle::Adapters::Kaminari::RelationExtension)
Riffle::Adapters::Kaminari.wrap_page_method(User)
Riffle::Adapters::Kaminari.wrap_page_method(UuidRecord)

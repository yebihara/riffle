# frozen_string_literal: true

require "active_support/current_attributes"

module Riffle
  class Current < ActiveSupport::CurrentAttributes
    attribute :enabled
    attribute :cursor_id
    attribute :page
  end
end

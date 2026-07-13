# frozen_string_literal: true

require "bundler/setup"
require "active_support"
require "riffle"

# Use memory store for testing
Riffle.store = Riffle::Store::Memory.new

RSpec.configure do |config|
  config.example_status_persistence_file_path = ".rspec_status"
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  config.before(:each) do
    Riffle.store.clear if Riffle.store.respond_to?(:clear)
  end
end

# frozen_string_literal: true

require "riffle/version"
require "riffle/error"
require "riffle/configuration"
require "riffle/current"

# Store
require "riffle/store/base"
require "riffle/store/redis"
require "riffle/store/memory"

# Core
require "riffle/core/cursor"
require "riffle/core/snapshot"
require "riffle/core/page_fetcher"

# Railtie (loads adapters conditionally)
require "riffle/railtie" if defined?(Rails)

module Riffle
  class << self
    def config
      @config ||= Configuration.new
    end

    def configure
      yield(config)
    end

    # Default store instance
    def store
      @store ||= Store::Redis.new
    end

    # Allow setting a custom store (useful for testing)
    def store=(store)
      @store = store
    end

    # Reset store (useful for testing)
    def reset_store!
      @store = nil
    end
  end
end

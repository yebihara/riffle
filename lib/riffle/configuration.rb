# frozen_string_literal: true

module Riffle
  class Configuration
    DEFAULT_REDIS_KEY_PREFIX = "riffle"

    # Behavior when a search returns more IDs than max_ids:
    #   :truncate (default) — cap at max_ids, emit a WARN log, mark the
    #                         cursor as truncated so the application can show
    #                         "results clipped"
    #   :raise              — abort with Riffle::MaxIdsExceeded so the caller
    #                         can prompt the user to narrow their search
    VALID_ON_MAX_IDS_EXCEEDED = %i[truncate raise].freeze

    # Behavior when a request arrives with a cursor_id that no longer exists
    # (TTL expiry, manual deletion, Redis flush):
    #   :auto (default) — silently create a new cursor and return the page
    #                     from the fresh result set. Best for casual UIs
    #                     where the user just wants something to come back.
    #   :strict         — raise Riffle::CursorExpired so the caller can
    #                     redirect the user to start a new search. Better
    #                     fit for SoR systems where snapshot continuity
    #                     matters more than convenience.
    VALID_ON_CURSOR_EXPIRED = %i[auto strict].freeze

    attr_accessor :redis, :ttl, :max_ids, :cursor_param, :logger,
                  :redis_key_prefix, :on_max_ids_exceeded,
                  :on_cursor_expired

    def initialize
      @redis = nil
      @ttl = 30 * 60 # 30 minutes in seconds
      @max_ids = 100_000
      @cursor_param = :cursor_id
      @logger = nil
      @redis_key_prefix = DEFAULT_REDIS_KEY_PREFIX
      @on_max_ids_exceeded = :truncate
      @on_cursor_expired = :auto
    end

    def on_max_ids_exceeded=(value)
      unless VALID_ON_MAX_IDS_EXCEEDED.include?(value)
        raise ConfigurationError,
              "on_max_ids_exceeded must be one of #{VALID_ON_MAX_IDS_EXCEEDED.inspect}, got #{value.inspect}"
      end
      @on_max_ids_exceeded = value
    end

    def on_cursor_expired=(value)
      unless VALID_ON_CURSOR_EXPIRED.include?(value)
        raise ConfigurationError,
              "on_cursor_expired must be one of #{VALID_ON_CURSOR_EXPIRED.inspect}, got #{value.inspect}"
      end
      @on_cursor_expired = value
    end

    def redis!
      raise ConfigurationError, "Redis is not configured. Please set Riffle.config.redis" unless @redis
      @redis
    end

    def logger
      @logger ||= default_logger
    end

    private

    def default_logger
      if defined?(Rails) && Rails.respond_to?(:logger)
        Rails.logger
      end
    end
  end
end

# frozen_string_literal: true

module Riffle
  class Error < StandardError; end
  class CursorNotFound < Error; end
  class CursorExpired < Error; end
  class ConfigurationError < Error; end
end

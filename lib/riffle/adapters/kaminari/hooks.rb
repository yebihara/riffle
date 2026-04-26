# frozen_string_literal: true

module Riffle
  module Adapters
    module Kaminari
      class << self
        def wrap_page_method(klass)
          return unless klass.respond_to?(:page)
          return if klass.singleton_class.method_defined?(:page_without_riffle)

          klass.singleton_class.class_eval do
            alias_method :page_without_riffle, :page

            define_method(:page) do |num = nil|
              result = page_without_riffle(num)
              if Riffle::Current.enabled
                result.riffle_enabled = true
              end
              result
            end
          end
        end
      end
    end
  end
end

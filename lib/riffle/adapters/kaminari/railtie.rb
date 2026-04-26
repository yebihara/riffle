# frozen_string_literal: true

module Riffle
  module Adapters
    module Kaminari
      class Railtie < Rails::Railtie
        initializer "riffle.kaminari" do
          ActiveSupport.on_load(:action_controller) do
            include Riffle::Adapters::Kaminari::ControllerMethods
          end

          ActiveSupport.on_load(:active_record) do
            ActiveRecord::Relation.prepend Riffle::Adapters::Kaminari::RelationExtension
          end

          ActiveSupport.on_load(:action_view) do
            prepend Riffle::Adapters::Kaminari::ViewHelpers
          end
        end

        config.to_prepare do
          if defined?(::Kaminari) && defined?(ApplicationRecord)
            Riffle::Adapters::Kaminari.wrap_page_method(ApplicationRecord)

            ActiveRecord::Base.descendants.each do |model|
              next if model.abstract_class?
              next unless model.respond_to?(:page)

              Riffle::Adapters::Kaminari.wrap_page_method(model)
            end
          end
        end
      end

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

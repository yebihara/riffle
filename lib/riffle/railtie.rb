# frozen_string_literal: true

module Riffle
  class Railtie < Rails::Railtie
    initializer "riffle.setup" do
      # Load Kaminari adapter if Kaminari is available
      ActiveSupport.on_load(:action_controller) do
        if defined?(::Kaminari)
          require "riffle/adapters/kaminari/controller_methods"
          include Riffle::Adapters::Kaminari::ControllerMethods
        end

        if defined?(::Pagy)
          require "riffle/adapters/pagy/backend"
          include Riffle::Adapters::Pagy::Backend
        end
      end

      ActiveSupport.on_load(:active_record) do
        if defined?(::Kaminari)
          require "riffle/adapters/kaminari/relation_extension"
          ActiveRecord::Relation.prepend Riffle::Adapters::Kaminari::RelationExtension
        end
      end

      ActiveSupport.on_load(:action_view) do
        if defined?(::Kaminari)
          require "riffle/adapters/kaminari/view_helpers"
          prepend Riffle::Adapters::Kaminari::ViewHelpers
        end

        if defined?(::Pagy)
          require "riffle/adapters/pagy/frontend"
          prepend Riffle::Adapters::Pagy::Frontend
        end
      end
    end

    config.to_prepare do
      if defined?(::Kaminari) && defined?(ApplicationRecord)
        require "riffle/adapters/kaminari/hooks"
        Riffle::Adapters::Kaminari.wrap_page_method(ApplicationRecord)

        ActiveRecord::Base.descendants.each do |model|
          next if model.abstract_class?
          next unless model.respond_to?(:page)

          Riffle::Adapters::Kaminari.wrap_page_method(model)
        end
      end
    end
  end
end

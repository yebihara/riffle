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
          require "riffle/adapters/pagy/compat"
          if Riffle::Adapters::Pagy.supported?
            require "riffle/adapters/pagy/backend"
            include Riffle::Adapters::Pagy::Backend
          else
            Riffle::Adapters::Pagy.warn_unsupported
          end
        end
      end

      ActiveSupport.on_load(:action_view) do
        if defined?(::Kaminari)
          require "riffle/adapters/kaminari/view_helpers"
          prepend Riffle::Adapters::Kaminari::ViewHelpers
        end

        if defined?(::Pagy)
          require "riffle/adapters/pagy/compat"
          if Riffle::Adapters::Pagy.supported?
            require "riffle/adapters/pagy/frontend"
            prepend Riffle::Adapters::Pagy::Frontend
          else
            Riffle::Adapters::Pagy.warn_unsupported
          end
        end
      end
    end
  end
end

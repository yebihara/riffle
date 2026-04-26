# frozen_string_literal: true

module Riffle
  module Adapters
    module Kaminari
      module ControllerMethods
        def self.included(base)
          base.extend(ClassMethods)
        end

        module ClassMethods
          # Enable Riffle for specific actions
          # @param enabled [Boolean] whether to enable riffle
          # @param options [Hash] options passed to before_action (:only, :except)
          def riffle(enabled = true, **options)
            before_action(**options.slice(:only, :except)) do
              cursor_param = Riffle.config.cursor_param
              Riffle::Current.enabled = enabled
              Riffle::Current.cursor_id = params[cursor_param]
              Riffle::Current.page = params[:page]
            end
          end
        end
      end
    end
  end
end

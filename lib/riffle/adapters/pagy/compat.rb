# frozen_string_literal: true

module Riffle
  module Adapters
    module Pagy
      # Version shim for the supported Pagy majors.
      #
      # Pagy 9 renamed the :items variable (and the matching request param)
      # to :limit. Pagy 43 is a full rewrite (Pagy::Backend / Pagy::Frontend
      # are gone) and needs a dedicated adapter, so it is explicitly not
      # supported here — see the tracking issue linked from the README.
      class << self
        def pagy_major
          ::Pagy::VERSION.split(".").first.to_i
        end

        def supported?
          [8, 9].include?(pagy_major)
        end

        # The Pagy var (and params key) controlling page size.
        def limit_var
          pagy_major >= 9 ? :limit : :items
        end

        def default_limit
          ::Pagy::DEFAULT[limit_var]
        end

        def warn_unsupported
          return if @warned_unsupported

          @warned_unsupported = true
          message = "[Riffle] Pagy #{::Pagy::VERSION} is not supported by the Riffle " \
                    "adapter (supported: 8.x and 9.x); skipping adapter setup. " \
                    "See https://github.com/yebihara/riffle for status."
          logger = Riffle.config.logger
          logger ? logger.warn(message) : Kernel.warn(message)
        end
      end
    end
  end
end

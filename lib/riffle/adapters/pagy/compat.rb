# frozen_string_literal: true

module Riffle
  module Adapters
    module Pagy
      # Version shim for the supported Pagy majors.
      #
      # Pagy 9 renamed the :items variable (and the matching request param)
      # to :limit. Pagy 43 is a full rewrite (Pagy::Backend / Pagy::Frontend
      # are gone, replaced by Pagy::Method / Pagy::Offset and the :querify
      # option) and needs a dedicated adapter implementation — see
      # backend_v43.rb / frontend_v43.rb.
      SUPPORTED_MAJORS = [8, 9, 43].freeze

      class << self
        def pagy_major
          ::Pagy::VERSION.split(".").first.to_i
        end

        def supported?
          SUPPORTED_MAJORS.include?(pagy_major)
        end

        # True for the ground-up-rewritten Pagy 43+ API.
        def v43?
          pagy_major >= 43
        end

        # The Pagy var (and params key) controlling page size. Pagy 43 kept
        # the :limit name introduced in Pagy 9.
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
                    "adapter (supported: 8.x, 9.x, and 43.x); skipping adapter setup. " \
                    "See https://github.com/yebihara/riffle for status."
          logger = Riffle.config.logger
          logger ? logger.warn(message) : Kernel.warn(message)
        end
      end
    end
  end
end

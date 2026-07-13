# frozen_string_literal: true

require "riffle/error"
require "riffle/adapters/pagy/compat"

# Loads the Pagy backend implementation matching the installed Pagy major and
# defines Riffle::Adapters::Pagy::Backend. Pagy 43 rewrote the pagination API,
# so it needs a separate implementation from the 8/9 (Pagy::Backend) era.
if defined?(::Pagy)
  # Direct requires bypass the railtie/extra supported? guard — warn (once)
  # on unsupported majors, then best-effort load the nearest implementation.
  Riffle::Adapters::Pagy.warn_unsupported unless Riffle::Adapters::Pagy.supported?
  if Riffle::Adapters::Pagy.v43?
    require "riffle/adapters/pagy/backend_v43"
  else
    require "riffle/adapters/pagy/backend_legacy"
  end
else
  # Pagy is not loaded yet, so the right implementation cannot be chosen —
  # silently defaulting to one of them would mis-bind apps that require this
  # file before pagy. Instead, resolve on the first pagy_riffle call:
  # requiring the implementation file reopens this module and replaces this
  # method, so the recursive call dispatches to the real implementation.
  module Riffle
    module Adapters
      module Pagy
        module Backend
          def pagy_riffle(collection, vars = {}, **options)
            unless defined?(::Pagy)
              raise Riffle::ConfigurationError,
                    "pagy_riffle needs the pagy gem: require \"pagy\" before calling it"
            end

            Riffle::Adapters::Pagy.warn_unsupported unless Riffle::Adapters::Pagy.supported?
            impl = Riffle::Adapters::Pagy.v43? ? "backend_v43" : "backend_legacy"
            require "riffle/adapters/pagy/#{impl}"

            combined = vars.empty? ? options : vars.merge(options)
            pagy_riffle(collection, combined)
          end
        end
      end
    end
  end
end

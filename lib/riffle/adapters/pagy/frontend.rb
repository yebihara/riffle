# frozen_string_literal: true

require "riffle/adapters/pagy/compat"

# Loads the Pagy frontend/view helpers matching the installed Pagy major and
# defines Riffle::Adapters::Pagy::Frontend. Pagy 43 removed pagy_url_for, so
# its frontend only carries the riffle_cursor_id / riffle_cursor_field helpers.
if Riffle::Adapters::Pagy.v43?
  require "riffle/adapters/pagy/frontend_v43"
else
  require "riffle/adapters/pagy/frontend_legacy"
end

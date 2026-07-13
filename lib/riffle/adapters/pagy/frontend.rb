# frozen_string_literal: true

require "riffle/adapters/pagy/compat"

# Loads the Pagy frontend/view helpers matching the installed Pagy major and
# defines Riffle::Adapters::Pagy::Frontend. Pagy 43 removed pagy_url_for, so
# its frontend only carries the riffle_cursor_id / riffle_cursor_field helpers.
# Direct requires bypass the railtie/extra supported? guard — warn (once) on
# unsupported majors, then best-effort load the nearest implementation.
if defined?(::Pagy) && !Riffle::Adapters::Pagy.supported?
  Riffle::Adapters::Pagy.warn_unsupported
end

if defined?(::Pagy) && Riffle::Adapters::Pagy.v43?
  require "riffle/adapters/pagy/frontend_v43"
else
  # Chosen for Pagy 8/9 — and also when Pagy is not loaded yet, because the
  # legacy module is a safe superset: its only 8/9-specific piece, the
  # pagy_url_for override, is never called on Pagy 43 (page links are built
  # from the backend's :querify option there), and the cursor helpers are
  # version-independent.
  require "riffle/adapters/pagy/frontend_legacy"
end

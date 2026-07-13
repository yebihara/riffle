# frozen_string_literal: true

require "riffle/adapters/fetch_support"

module Riffle
  module Adapters
    module Kaminari
      # Injected into a SINGLE ActiveRecord::Relation via #extending (the public
      # AR API for per-instance modules) by Riffle::Model#riffle. It overrides
      # +records+ and +total_count+ for that one relation only, sourcing them
      # from a Riffle cursor/snapshot instead of a live OFFSET query.
      #
      # Ordering matters. Kaminari defines +total_count+ in a module it mixes in
      # at +.page+ time (Kaminari::ActiveRecordRelationMethods). Ruby will not
      # reorder a module that is already in the singleton ancestry, so if riffle
      # were applied *before* +.page+, Kaminari's +total_count+ would sit ahead
      # of this one and win. Applying riffle *after* +.page+/+.per+ puts this
      # module closest to the object, so its overrides win and +super+ reaches
      # the normal implementations. +.riffle+ is therefore the terminal call in
      # the chain (verified against kaminari 1.2.2 + activerecord 8.1).
      #
      # State set here (cursor id/param, loaded records) rides on the relation's
      # instance variables, which survive +spawn+/+clone+ (and thus +.except+),
      # keeping each paginated collection independent — the fix for the
      # request-global cursor corruption of the old design. Note that +merge+
      # does not carry instance variables, so +other.merge(riffled_scope)+ is
      # unsupported.
      module RelationRiffle
        include Riffle::Adapters::FetchSupport

        # Stores per-relation cursor state. Called by Riffle::Model#riffle right
        # after +extending+. Returns self so it chains.
        def riffle_setup(cursor_id: nil, param: nil, store: nil)
          @riffle_cursor_id = cursor_id
          @riffle_cursor_param = (param || Riffle.config.cursor_param).to_sym
          @riffle_store = store
          self
        end

        # The cursor id that page links / forms must echo back. Reading it forces
        # the fetch, because a brand-new snapshot's id is only known afterward.
        def riffle_cursor_id
          riffle_load
          @riffle_cursor_id
        end

        # The request param name this collection reads/writes its cursor under.
        # Per-relation so two paginators on one page never share a cursor param.
        def riffle_cursor_param
          if defined?(@riffle_cursor_param) && @riffle_cursor_param
            @riffle_cursor_param
          else
            Riffle.config.cursor_param
          end
        end

        def records
          return super if riffle_bypass?

          riffle_load
          @riffle_records
        end

        # Signature matches Kaminari::ActiveRecordRelationMethods#total_count.
        def total_count(column_name = :all, _options = nil)
          return super if riffle_bypass?

          riffle_load
          @riffle_total_count
        end

        # Marks this relation as a plain relation again so its records /
        # total_count fall through to +super+. Set on the inner per-page query
        # (a clone that still carries this module) so loading it does not recurse
        # back into riffle_load.
        def riffle_bypass!
          @riffle_bypass = true
          self
        end

        private

        def riffle_bypass?
          defined?(@riffle_bypass) && @riffle_bypass
        end

        def riffle_load
          return if defined?(@riffle_loaded) && @riffle_loaded

          riffle_assert_chain_order!

          page_num = respond_to?(:current_page) ? (current_page || 1) : 1
          per_page = limit_value || ::Kaminari.config.default_per_page
          store = @riffle_store || Riffle.store

          # Drop pagination clauses and disarm riffle on the scope handed to the
          # fetcher: its WHERE-by-ids / pluck queries must not recurse.
          base_scope = except(:limit, :offset)
          base_scope.riffle_bypass!

          result = riffle_fetch_result(@riffle_cursor_id, base_scope, page_num, per_page, store)

          @riffle_records     = result[:records]
          @riffle_total_count = result[:total_count]
          @riffle_cursor_id   = result[:cursor_id]
          @riffle_loaded      = true
        end

        # Guard the chain-order requirement. When .riffle is applied BEFORE
        # .page, Kaminari's own total_count (mixed in at .page time) sits ahead
        # of this module in the singleton ancestry and wins, so total_count /
        # total_pages would silently report the live table count instead of the
        # snapshot. Records still load correctly through this module, so this
        # check runs on the records path and turns that silent wrong-count into
        # a loud, actionable error. When .page was never called (Layer 1 without
        # Kaminari pagination) there is nothing to shadow, so it is a no-op.
        def riffle_assert_chain_order!
          return unless defined?(::Kaminari::ActiveRecordRelationMethods)

          ancestry = singleton_class.ancestors
          kaminari_idx = ancestry.index(::Kaminari::ActiveRecordRelationMethods)
          return if kaminari_idx.nil?

          riffle_idx = ancestry.index(RelationRiffle)
          return if riffle_idx && riffle_idx < kaminari_idx

          raise Riffle::ConfigurationError,
                "Riffle: chain .riffle AFTER .page/.per, e.g. " \
                "`User.order(:name).page(n).per(20).riffle(cursor: ...)`. " \
                "It was applied before Kaminari's pagination, so Kaminari's " \
                "total_count shadows riffle's and would report the live table " \
                "count instead of the cursor snapshot."
        end
      end
    end
  end
end

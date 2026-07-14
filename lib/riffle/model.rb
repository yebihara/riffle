# frozen_string_literal: true

require "active_support/concern"
require "riffle/adapters/kaminari/relation_riffle"

module Riffle
  # Opt a model into riffle's Kaminari integration:
  #
  #   class ApplicationRecord < ActiveRecord::Base
  #     include Riffle::Model
  #   end
  #
  # This adds a +riffle+ scope method (usable at the class level and, like
  # Kaminari's +page+, on any relation) that returns a cursor-backed relation.
  # Chain it AFTER +.page+/+.per+ so its overrides win over Kaminari's — see
  # Riffle::Adapters::Kaminari::RelationRiffle for why:
  #
  #   @users = User.order(:name)
  #                .page(params[:page]).per(20)
  #                .riffle(cursor: params[:cursor_id])
  #
  # Kaminari is optional. Headless callers (JSON APIs, jobs) can state the
  # page and size directly and read the response metadata from +riffle_meta+:
  #
  #   users = User.order(:name)
  #               .riffle(cursor: params[:cursor_id], page: params[:page], per: 20)
  #   render json: { users: users.records, meta: users.riffle_meta }
  #
  # Each call produces an independent snapshot; pass a distinct +param:+ to
  # paginate two collections on one page without them clobbering each other.
  module Model
    extend ActiveSupport::Concern

    class_methods do
      # @param cursor [String, nil] the incoming cursor id (nil starts a fresh
      #   snapshot)
      # @param page [Integer, String, nil] page number for headless use without
      #   Kaminari's +.page+; clamped to >= 1. When both are present, this
      #   keyword wins over the chained Kaminari value.
      # @param per [Integer, String, nil] page size for headless use without
      #   Kaminari's +.per+ / +.limit+; wins over the chained value likewise.
      # @param param [Symbol, String, nil] request param name this collection
      #   reads/writes its cursor under (defaults to Riffle.config.cursor_param)
      # @param store [Riffle::Store::Base, nil] override the store for this
      #   relation (defaults to Riffle.store)
      # @return [ActiveRecord::Relation] extended with RelationRiffle
      def riffle(cursor: nil, page: nil, per: nil, param: nil, store: nil)
        all.extending(Riffle::Adapters::Kaminari::RelationRiffle)
           .riffle_setup(cursor_id: cursor, page: page, per: per, param: param, store: store)
      end
    end
  end
end

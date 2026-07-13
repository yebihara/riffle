# frozen_string_literal: true

require "active_support/all"
require "uri"
require "riffle/adapters/kaminari/view_helpers"

RSpec.describe Riffle::Adapters::Kaminari::ViewHelpers do
  let(:host_class) do
    Class.new do
      def paginate(scope, paginator_class: nil, template: nil, **options)
        # Stub: capture and return the args for inspection
        { scope: scope, paginator_class: paginator_class, template: template, options: options }
      end

      def hidden_field_tag(name, value)
        %(<input type="hidden" name="#{name}" value="#{value}">)
      end

      def url_for(params)
        "/users?#{URI.encode_www_form(params.stringify_keys)}"
      end
    end.tap do |c|
      c.prepend(Riffle::Adapters::Kaminari::ViewHelpers)
    end
  end

  let(:helper) { host_class.new }

  # Build a fake paginated scope carrying a per-relation cursor id + param,
  # mirroring what RelationRiffle exposes.
  def scope_with(cursor_id:, param: :cursor_id)
    obj = Object.new
    obj.define_singleton_method(:riffle_cursor_id) { cursor_id }
    obj.define_singleton_method(:riffle_cursor_param) { param }
    obj
  end

  let(:scope_with_cursor) { scope_with(cursor_id: "abc123") }

  let(:scope_without_cursor) { scope_with(cursor_id: nil) }

  let(:bare_scope) { Object.new }  # does not respond to :riffle_cursor_id

  describe "#paginate" do
    it "injects cursor_id into options[:params]" do
      result = helper.paginate(scope_with_cursor)
      expect(result[:options][:params][:cursor_id]).to eq("abc123")
    end

    it "preserves explicitly-passed params and adds cursor_id" do
      result = helper.paginate(scope_with_cursor, params: { foo: "bar" })
      expect(result[:options][:params]).to eq(foo: "bar", cursor_id: "abc123")
    end

    it "passes through unmodified when scope has no cursor_id" do
      result = helper.paginate(scope_without_cursor)
      expect(result[:options][:params]).to be_nil
    end

    it "passes through unmodified for scopes without the helper method" do
      result = helper.paginate(bare_scope)
      expect(result[:options][:params]).to be_nil
    end

    it "injects under the scope's per-relation cursor param" do
      scope = scope_with(cursor_id: "abc123", param: :users_cursor)
      result = helper.paginate(scope)
      expect(result[:options][:params][:users_cursor]).to eq("abc123")
    end

    it "carries different params for two paginators on one page" do
      users = scope_with(cursor_id: "u-1", param: :users_cursor)
      posts = scope_with(cursor_id: "p-1", param: :posts_cursor)

      users_result = helper.paginate(users)
      posts_result = helper.paginate(posts)

      expect(users_result[:options][:params]).to eq(users_cursor: "u-1")
      expect(posts_result[:options][:params]).to eq(posts_cursor: "p-1")
    end
  end

  describe "#riffle_cursor_id" do
    it "returns the scope's cursor_id when present" do
      expect(helper.riffle_cursor_id(scope_with_cursor)).to eq("abc123")
    end

    it "returns nil when scope does not respond to :riffle_cursor_id" do
      expect(helper.riffle_cursor_id(bare_scope)).to be_nil
    end
  end

  describe "#riffle_cursor_field" do
    it "renders a hidden_field_tag with cursor_id" do
      result = helper.riffle_cursor_field(scope_with_cursor)
      expect(result).to eq(%(<input type="hidden" name="cursor_id" value="abc123">))
    end

    it "returns nil when there is no cursor_id" do
      expect(helper.riffle_cursor_field(scope_without_cursor)).to be_nil
    end
  end

  describe "#riffle_path" do
    context "with a String base_path" do
      it "appends cursor_id as a query parameter" do
        result = helper.riffle_path("/users", scope_with_cursor, page: 2)
        expect(result).to include("cursor_id=abc123")
        expect(result).to include("page=2")
      end

      it "preserves existing query parameters" do
        result = helper.riffle_path("/users?role=admin", scope_with_cursor, page: 2)
        expect(result).to include("role=admin")
        expect(result).to include("cursor_id=abc123")
      end

      it "returns the merged URL even without cursor_id" do
        result = helper.riffle_path("/users", scope_without_cursor, page: 2)
        expect(result).to include("page=2")
        expect(result).not_to include("cursor_id=")
      end
    end

    context "with a Hash base_path" do
      it "delegates to url_for with merged params" do
        result = helper.riffle_path({ controller: "users" }, scope_with_cursor, page: 2)
        expect(result).to include("cursor_id=abc123")
        expect(result).to include("page=2")
      end
    end
  end
end

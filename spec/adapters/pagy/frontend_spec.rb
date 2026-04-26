# frozen_string_literal: true

require "pagy"
require "riffle/adapters/pagy/frontend"

RSpec.describe Riffle::Adapters::Pagy::Frontend do
  # Stub the parent pagy_url_for so we can test our prepend override in isolation
  # (the real Pagy implementation needs request/env which isn't available here).
  let(:base_url) { "/users?page=2" }
  let(:base_class) do
    base = base_url
    Class.new do
      define_method(:pagy_url_for) do |_pagy, _page, absolute: false, html_escaped: false|
        base
      end

      def hidden_field_tag(name, value)
        %(<input type="hidden" name="#{name}" value="#{value}">)
      end
    end
  end

  let(:host_class) do
    klass = base_class
    Class.new(klass) do
      prepend Riffle::Adapters::Pagy::Frontend
    end
  end

  let(:helper) { host_class.new }
  let(:cursor_id) { "abc123xyz" }
  let(:pagy_with_cursor) do
    obj = Object.new
    cid = cursor_id
    obj.define_singleton_method(:riffle_cursor_id) { cid }
    obj
  end
  let(:pagy_without_cursor) { Object.new }

  describe "#pagy_url_for" do
    it "appends cursor_id when the pagy carries riffle_cursor_id" do
      result = helper.pagy_url_for(pagy_with_cursor, 2)
      expect(result).to eq("/users?page=2&cursor_id=#{cursor_id}")
    end

    it "uses ? when the URL has no query string" do
      allow(helper).to receive(:pagy_url_for).and_call_original
      simple_base = Class.new do
        define_method(:pagy_url_for) do |_pagy, _page, absolute: false, html_escaped: false|
          "/users"
        end
      end
      host = Class.new(simple_base) { prepend Riffle::Adapters::Pagy::Frontend }
      result = host.new.pagy_url_for(pagy_with_cursor, 2)
      expect(result).to eq("/users?cursor_id=#{cursor_id}")
    end

    it "delegates to super when the pagy has no riffle_cursor_id" do
      result = helper.pagy_url_for(pagy_without_cursor, 2)
      expect(result).to eq(base_url)
    end

    it "html-escapes ampersand when html_escaped: true" do
      result = helper.pagy_url_for(pagy_with_cursor, 2, html_escaped: true)
      expect(result).to include("&amp;cursor_id=#{cursor_id}")
    end

    it "honors a custom Configuration.cursor_param" do
      Riffle.config.cursor_param = :rfl
      result = helper.pagy_url_for(pagy_with_cursor, 2)
      expect(result).to eq("/users?page=2&rfl=#{cursor_id}")
    ensure
      Riffle.config.cursor_param = :cursor_id
    end
  end

  describe "#riffle_cursor_id" do
    it "returns the cursor_id when present" do
      expect(helper.riffle_cursor_id(pagy_with_cursor)).to eq(cursor_id)
    end

    it "returns nil when the pagy lacks the helper method" do
      expect(helper.riffle_cursor_id(pagy_without_cursor)).to be_nil
    end
  end

  describe "#riffle_cursor_field" do
    it "renders a hidden_field_tag with the cursor_id" do
      result = helper.riffle_cursor_field(pagy_with_cursor)
      expect(result).to eq(%(<input type="hidden" name="cursor_id" value="#{cursor_id}">))
    end

    it "returns nil when there is no cursor_id" do
      expect(helper.riffle_cursor_field(pagy_without_cursor)).to be_nil
    end
  end
end

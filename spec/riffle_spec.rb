# frozen_string_literal: true

RSpec.describe Riffle do
  it "has a version number" do
    expect(Riffle::VERSION).not_to be_nil
  end

  describe ".config" do
    it "returns a Configuration instance" do
      expect(Riffle.config).to be_a(Riffle::Configuration)
    end

    it "has default values" do
      expect(Riffle.config.ttl).to eq(30 * 60)
      expect(Riffle.config.max_ids).to eq(100_000)
      expect(Riffle.config.cursor_param).to eq(:cursor_id)
      expect(Riffle.config.redis_key_prefix).to eq("riffle")
    end
  end

  describe ".configure" do
    it "yields the configuration" do
      Riffle.configure do |config|
        config.ttl = 60 * 60
      end

      expect(Riffle.config.ttl).to eq(60 * 60)
    end
  end

  describe ".store" do
    it "returns a store instance" do
      expect(Riffle.store).to be_a(Riffle::Store::Base)
    end
  end
end

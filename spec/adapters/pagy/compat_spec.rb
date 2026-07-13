# frozen_string_literal: true

require "pagy"
require "riffle/adapters/pagy/compat"

RSpec.describe Riffle::Adapters::Pagy do
  describe ".pagy_major" do
    it "reflects the installed Pagy version" do
      expect(described_class.pagy_major).to eq(::Pagy::VERSION.split(".").first.to_i)
    end
  end

  describe ".supported?" do
    it "is true for the installed version this suite runs against" do
      expect(described_class.supported?).to be true
    end

    it "is false for Pagy 43 and other unsupported majors" do
      allow(described_class).to receive(:pagy_major).and_return(43)
      expect(described_class.supported?).to be false
    end
  end

  describe ".limit_var" do
    it "is :items on Pagy 8 and :limit on Pagy 9+" do
      expected = described_class.pagy_major >= 9 ? :limit : :items
      expect(described_class.limit_var).to eq(expected)
    end
  end

  describe ".default_limit" do
    it "reads Pagy's default page size" do
      expect(described_class.default_limit).to eq(::Pagy::DEFAULT[described_class.limit_var])
    end
  end

  describe ".warn_unsupported" do
    after { described_class.instance_variable_set(:@warned_unsupported, nil) }

    it "warns through the configured logger, once" do
      logger = instance_double(Logger)
      allow(Riffle.config).to receive(:logger).and_return(logger)

      expect(logger).to receive(:warn).once.with(/Pagy #{Regexp.escape(::Pagy::VERSION)} is not supported/)
      described_class.warn_unsupported
      described_class.warn_unsupported
    end
  end
end

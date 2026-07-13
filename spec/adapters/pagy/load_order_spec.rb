# frozen_string_literal: true

# Requiring the Pagy adapter before the pagy gem must not bind the wrong
# implementation (or crash). The dispatcher defers the version check to the
# first pagy_riffle call, so this has to be exercised in a subprocess where
# pagy is genuinely not loaded yet.
RSpec.describe "Pagy adapter require-order resilience" do
  it "resolves the implementation at first call when required before pagy" do
    script = <<~'RUBY'
      $LOAD_PATH.unshift(File.expand_path("lib", Dir.pwd))
      require "riffle/adapters/pagy/backend"

      if $LOADED_FEATURES.any? { |f| f =~ /backend_(v43|legacy)/ }
        abort "implementation chosen before pagy was loaded"
      end

      # Exercise both binding styles: production (railtie/extra) uses
      # include, so verify the placeholder's in-place method replacement
      # propagates to includers as well as to extended objects. Each stub
      # exposes #params so the real implementation gets past its
      # request-source check and fails later (nil collection) instead of
      # raising its own ConfigurationError.
      extended = Object.new.extend(Riffle::Adapters::Pagy::Backend)
      def extended.params = {}

      included = Class.new do
        include Riffle::Adapters::Pagy::Backend
        def params = {}
      end.new

      [extended, included].each do |obj|
        begin
          obj.pagy_riffle(nil)
          abort "expected ConfigurationError while pagy is not loaded"
        rescue Riffle::ConfigurationError
        end
      end

      require "pagy"
      [extended, included].each do |obj|
        begin
          obj.pagy_riffle(nil)
        rescue Riffle::ConfigurationError => e
          abort "dispatcher did not resolve after pagy was loaded: #{e.message}"
        rescue StandardError
          # nil collection fails inside the real implementation — irrelevant;
          # we only care which implementation the dispatcher loaded.
        end
      end

      expected = Pagy::VERSION.split(".").first.to_i >= 43 ? "backend_v43" : "backend_legacy"
      abort "wrong implementation loaded" unless $LOADED_FEATURES.any? { |f| f.include?(expected) }
      puts "OK"
    RUBY

    output = IO.popen([RbConfig.ruby, "-e", script], err: %i[child out], &:read)
    expect(output).to include("OK"), "subprocess output: #{output}"
  end
end

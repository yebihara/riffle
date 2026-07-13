# frozen_string_literal: true

# Requiring the Pagy adapter before the pagy gem must not bind the wrong
# implementation (or crash). The dispatcher defers the version check to the
# first pagy_riffle call, so this has to be exercised in a subprocess where
# pagy is genuinely not loaded yet.
RSpec.describe "Pagy adapter require-order resilience" do
  it "resolves the implementation at first call when required before pagy" do
    script = <<~RUBY
      $LOAD_PATH.unshift(File.expand_path("lib", Dir.pwd))
      require "riffle/adapters/pagy/backend"

      if $LOADED_FEATURES.any? { |f| f =~ /backend_(v43|legacy)/ }
        abort "implementation chosen before pagy was loaded"
      end

      obj = Object.new.extend(Riffle::Adapters::Pagy::Backend)
      begin
        obj.pagy_riffle(nil)
        abort "expected ConfigurationError while pagy is not loaded"
      rescue Riffle::ConfigurationError
      end

      require "pagy"
      begin
        obj.pagy_riffle(nil)
      rescue StandardError
        # nil collection fails inside the real implementation — irrelevant;
        # we only care which implementation the dispatcher loaded.
      end

      expected = Pagy::VERSION.split(".").first.to_i >= 43 ? "backend_v43" : "backend_legacy"
      abort "wrong implementation loaded" unless $LOADED_FEATURES.any? { |f| f.include?(expected) }
      puts "OK"
    RUBY

    output = IO.popen([RbConfig.ruby, "-e", script], err: %i[child out], &:read)
    expect(output).to include("OK"), "subprocess output: #{output}"
  end
end

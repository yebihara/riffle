# frozen_string_literal: true

lib = File.expand_path("../lib", __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require "riffle/version"

Gem::Specification.new do |spec|
  spec.name          = "riffle"
  spec.version       = Riffle::VERSION
  spec.authors       = ["EBIHARA, Yuichiro"]
  spec.email         = ["yuichiro.ebihara@gmail.com"]

  spec.summary       = "Skip-free, duplicate-free pagination for Rails, backed by Redis snapshots"
  spec.description   = "Riffle caches a search result's ID list in Redis and freezes its membership and order, so users never see rows skipped or duplicated while paging — even under concurrent inserts, deletes, and reordering. As a side effect, it also solves the deep OFFSET pagination performance problem. Works with Kaminari and Pagy."
  spec.homepage      = "https://github.com/yebihara/riffle"
  spec.license       = "MIT"

  spec.required_ruby_version = ">= 3.1.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"

  spec.files         = Dir.chdir(File.expand_path('..', __FILE__)) do
    `git ls-files -z`.split("\x0").reject { |f| f.match(%r{^(test|spec|features)/}) }
  end
  spec.bindir        = "exe"
  spec.executables   = spec.files.grep(%r{^exe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency "redis", ">= 4.0"
  spec.add_dependency "railties", ">= 7.0"
  spec.add_dependency "activesupport", ">= 7.0"

  spec.add_development_dependency "bundler", ">= 2.0"
  spec.add_development_dependency "rake", ">= 13.0"
  spec.add_development_dependency "rspec", "~> 3.0"
  spec.add_development_dependency "mock_redis", "~> 0.49"
  spec.add_development_dependency "activerecord", ">= 6.0"
  spec.add_development_dependency "sqlite3", ">= 1.4"
  spec.add_development_dependency "kaminari", "~> 1.2"
  spec.add_development_dependency "pagy", ">= 8.0"
end

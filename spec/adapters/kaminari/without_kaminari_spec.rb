# frozen_string_literal: true

# Riffle::Model (Layer 1) must work in apps that don't bundle Kaminari at all
# (e.g. Pagy-only apps): lib/riffle.rb loads it unconditionally, so any load-
# or call-time ::Kaminari reference is a crash there. The main suite always has
# Kaminari loaded, so this has to run in a subprocess.
RSpec.describe "Riffle::Model without Kaminari" do
  it "paginates with an explicit limit and gives a clear error without one" do
    script = <<~'RUBY'
      $LOAD_PATH.unshift(File.expand_path("lib", Dir.pwd))
      require "active_record"
      require "riffle"

      abort "Kaminari unexpectedly loaded" if defined?(::Kaminari)

      ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
      ActiveRecord::Base.connection.create_table(:users) { |t| t.string :name }

      class User < ActiveRecord::Base
        include Riffle::Model
      end

      Riffle.store = Riffle::Store::Memory.new(ttl: 60, max_ids: 100)
      3.times { |i| User.create!(name: "u#{i}") }

      begin
        User.order(:name).riffle(cursor: nil).records
        abort "expected ConfigurationError when no page size is given"
      rescue Riffle::ConfigurationError => e
        abort "unhelpful message: #{e.message}" unless e.message.include?("limit")
      end

      records = User.order(:name).limit(2).riffle(cursor: nil).records
      abort "wrong records: #{records.map(&:name)}" unless records.map(&:name) == %w[u0 u1]

      # The headless page:/per: keywords and riffle_meta must work with no
      # pagination gem at all — that is their reason to exist.
      first = User.order(:name).riffle(cursor: nil, page: 1, per: 2)
      meta = first.riffle_meta
      expected = { page: 1, per_page: 2, total_count: 3, total_pages: 2, next_page: 2, prev_page: nil }
      abort "wrong meta: #{meta}" unless meta == expected.merge(cursor_id: first.riffle_cursor_id)

      second = User.order(:name).riffle(cursor: first.riffle_cursor_id, page: 2, per: 2)
      abort "wrong page 2: #{second.records.map(&:name)}" unless second.records.map(&:name) == %w[u2]
      abort "cursor not reused" unless second.riffle_cursor_id == first.riffle_cursor_id
      puts "OK"
    RUBY

    output = IO.popen([RbConfig.ruby, "-e", script], err: %i[child out], &:read)
    expect(output).to include("OK"), "subprocess output: #{output}"
  end
end

#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Compare plain Kaminari vs Riffle for deep pagination performance.
#
# Plain Kaminari issues `LIMIT 20 OFFSET 80000` for page 4000, which forces
# the database to scan and discard 80,000 rows even with an index. Riffle
# materializes the full ID list once into Redis (via the in-memory store
# here, which has the same algorithmic shape) and then slices the cached
# array in O(log N + page_size) regardless of page number.
#
# Usage:
#   $ bundle exec ruby benchmark/deep_pagination.rb [num_records]
# Default num_records is 100_000.

require "bundler/setup"
require "benchmark"
require "active_record"
require "kaminari"
require "kaminari/activerecord"
require "logger"
require_relative "../lib/riffle"

NUM_RECORDS  = (ARGV[0] || 100_000).to_i
ITERATIONS   = 5
PER_PAGE     = 20
DEEP_PAGE    = NUM_RECORDS / PER_PAGE / 2 # middle of the dataset

ActiveRecord::Base.logger = Logger.new(IO::NULL)
ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")

ActiveRecord::Schema.define do
  self.verbose = false
  create_table :widgets, force: true do |t|
    t.string :name
    t.timestamps
  end
  add_index :widgets, :name
end

class Widget < ActiveRecord::Base
  include Riffle::Model
end

# Use the bundled Memory store so this benchmark runs without a Redis daemon.
# The algorithmic shape (slice a cached ID array, then WHERE id IN) is the
# same as the Redis store; absolute numbers will differ from production but
# the page=1 vs page=N relationship is what matters here.
Riffle.store = Riffle::Store::Memory.new(ttl: 600, max_ids: 1_000_000)

puts "Seeding #{NUM_RECORDS} widgets..."
Widget.transaction do
  NUM_RECORDS.times do |i|
    Widget.create!(name: "widget-#{i.to_s.rjust(7, '0')}")
  end
end
puts "Done seeding."
puts

def time_iterations(label, iterations:)
  realtimes = iterations.times.map { Benchmark.realtime { yield } }
  median = realtimes.sort[realtimes.size / 2]
  printf "  %-40s median=%6.2f ms  (n=%d)\n", label, median * 1000, iterations
  median
end

puts "Plain Kaminari (LIMIT/OFFSET)"
puts "-" * 60
plain_p1 = time_iterations("page 1, per_page #{PER_PAGE}", iterations: ITERATIONS) do
  Widget.order(:name).page(1).per(PER_PAGE).records.to_a
end
plain_pn = time_iterations("page #{DEEP_PAGE}, per_page #{PER_PAGE}", iterations: ITERATIONS) do
  Widget.order(:name).page(DEEP_PAGE).per(PER_PAGE).records.to_a
end
puts

puts "Riffle (snapshot reuse with cursor_id)"
puts "-" * 60

# First request: materializes the cursor.
seed = Widget.order(:name).page(1).per(PER_PAGE).riffle(cursor: nil)
seed.records # force load
cursor_id = seed.riffle_cursor_id

riffle_p1 = time_iterations("page 1, per_page #{PER_PAGE} (cursor reuse)", iterations: ITERATIONS) do
  Widget.order(:name).page(1).per(PER_PAGE).riffle(cursor: cursor_id).records.to_a
end
riffle_pn = time_iterations("page #{DEEP_PAGE}, per_page #{PER_PAGE} (cursor reuse)", iterations: ITERATIONS) do
  Widget.order(:name).page(DEEP_PAGE).per(PER_PAGE).riffle(cursor: cursor_id).records.to_a
end
puts

puts "Summary"
puts "-" * 60
printf "  Plain Kaminari deep/shallow ratio: %.2fx slower at page %d\n",
       plain_pn / plain_p1, DEEP_PAGE
printf "  Riffle         deep/shallow ratio: %.2fx slower at page %d\n",
       riffle_pn / riffle_p1, DEEP_PAGE
printf "  Riffle vs Kaminari at page %d:    %.2fx faster\n",
       DEEP_PAGE, plain_pn / riffle_pn

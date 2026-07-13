# Riffle

**Application-level Repeatable Read for paginated queries.**

Riffle brings database-style snapshot isolation to your Rails pagination.
By caching the result-set ID list in Redis on the first request, it
eliminates phantom reads across page navigation — users see a
consistent, frozen view of their search results no matter how many
times they navigate between pages, even if records are inserted,
deleted, or reordered in the meantime.

As a side effect, it also solves the classic OFFSET deep-pagination
performance problem: page navigation is `O(log N + page_size)`
regardless of page number, since the database is never asked to skip
rows.

Works with Kaminari and Pagy. An in-memory store is bundled for
testing without Redis.

[日本語ドキュメント](README_ja.md)

## Why Riffle?

In typical Rails pagination, each page navigation issues an independent
SQL query. Two well-known problems follow:

### 1. Phantom reads across pages (correctness)

If records are inserted, deleted, or reordered between page 1 and
page 2:

- **Skip**: a record that *should* appear on page 2 is bumped to page 1
  by a deletion above it; the user never sees it.
- **Duplicate**: a record visible on page 1 is bumped down to page 2 by
  an insertion above it; the user sees it twice.
- **Inconsistent counts**: total page count shifts mid-navigation.

This is the *phantom read anomaly* — the same problem that DB
isolation levels (Repeatable Read, Snapshot Isolation) exist to solve.
But HTTP pagination spans multiple stateless requests, so a single DB
transaction cannot bridge them.

### 2. Deep pagination performance (latency)

`OFFSET 100000 LIMIT 20` forces the DB to scan and discard 100,000 rows.
Latency grows linearly with page number.

### How Riffle solves both

On the first request, Riffle materializes the full result-set ID list
into a Redis Sorted Set, generating an unguessable `cursor_id` to
identify that snapshot. Subsequent page navigation:

1. Slices the cached ID array (one Redis pipelined RTT, independent of page number).
2. Fetches the actual records by primary key (`WHERE id IN (...)`).
3. Returns the same records the first request would have returned for
   that page — even if the underlying data has changed.

The cache TTL acts as the snapshot's lifetime. Within that window the
user sees a frozen, repeatable view, exactly as if a long-lived DB
transaction were holding the query's snapshot.

## Pagination Strategies Compared

| Strategy | Phantom-free across pages | Deep pagination perf | Page-number jump |
|---|:---:|:---:|:---:|
| Plain Kaminari / Pagy (OFFSET) | ❌ | ❌ | ✅ |
| Pagy::Countless | ❌ | ⚠️ (no COUNT, OFFSET still) | ✅ |
| Pagy::Keyset (cursor) | ❌ (no snapshot) | ✅ | ❌ (next/prev only) |
| Deferred Join | ❌ | ✅ | ✅ |
| Elasticsearch scroll / PIT | ✅ | ✅ | ⚠️ |
| **Riffle** | **✅** | **✅** | **✅** |

Riffle is the only Ruby/Rails-native option that delivers all three
properties without requiring Elasticsearch or DB-specific tricks.

## How It Works

```
┌─────────────────────────────────────┐
│  kaminari adapter / pagy adapter    │  ← Adapter layer
├─────────────────────────────────────┤
│            riffle (core)            │  ← Core API layer
├─────────────────────────────────────┤
│         Redis Sorted Set            │  ← Storage layer
└─────────────────────────────────────┘
```

1. On the first request, fetch all matching record IDs and cache them
   in Redis under a randomly generated `cursor_id`.
2. On subsequent pages, slice the cached ID list and fetch records by
   those IDs. Records deleted in the meantime are detected and
   backfilled from the next IDs in the snapshot.
3. The `cursor_id` is propagated in pagination links so every page
   navigation lands on the same snapshot until the TTL expires.

## Supported Versions

| Dependency | Supported |
|---|---|
| Ruby | >= 3.1 |
| Rails (railties / activesupport) | >= 7.0 |
| Kaminari | ~> 1.2 |
| Pagy | 8.x and 9.x |

Pagy 43+ is a ground-up rewrite of Pagy and requires a dedicated
adapter — tracked in
[#5](https://github.com/yebihara/riffle/issues/5). When an unsupported
Pagy version is detected, Riffle logs a warning and skips the Pagy
adapter instead of breaking your app (the Kaminari adapter and Core API
are unaffected).

Note that Pagy renamed the page-size variable from `:items` (Pagy 8) to
`:limit` (Pagy 9). `pagy_riffle` follows the convention of your
installed Pagy version.

## Installation

Add to your Gemfile:

```ruby
gem 'riffle'
```

Then run:

```bash
$ bundle install
```

## Configuration

Create `config/initializers/riffle.rb`:

```ruby
Riffle.configure do |config|
  # Redis connection (required)
  config.redis = Redis.new(url: ENV['REDIS_URL'])

  # Cache TTL (default: 30 minutes)
  config.ttl = 30 * 60

  # Maximum IDs to cache (default: 100,000)
  config.max_ids = 100_000

  # Behavior when a search produces more IDs than max_ids:
  #   :truncate (default) — cap at max_ids, log a warning, and mark the
  #                         cursor as truncated so the app can show
  #                         "showing first N of M+" via result.truncated?
  #   :raise              — abort with Riffle::MaxIdsExceeded so the
  #                         caller can prompt the user to narrow their search
  config.on_max_ids_exceeded = :truncate

  # Behavior when a request arrives with a cursor_id that no longer
  # exists (TTL expiry, manual deletion, Redis flush):
  #   :auto (default) — silently create a new cursor and return the page
  #                     from the fresh result set.
  #   :strict         — raise Riffle::CursorExpired so the caller can
  #                     redirect the user to start a new search; preferred
  #                     for SoR systems where snapshot continuity matters.
  config.on_cursor_expired = :auto

  # Cursor parameter name (default: :cursor_id)
  config.cursor_param = :cursor_id

  # Redis key prefix (default: "riffle")
  config.redis_key_prefix = "riffle"

  # Logger (default: Rails.logger)
  # config.logger = Rails.logger
end
```

### Logging

Set `config.logger` to enable store operation logging (INFO level).

```ruby
Riffle.configure do |config|
  config.logger = Rails.logger
end
```

**Redis store output example:**
```
[Riffle] STORE cursor_id=abc123 ids_count=1000 total_count=1000 ttl=1800s
[Riffle] ZADD riffle:abc123:ids (1000 members)
[Riffle] EXISTS cursor_id=abc123 result=true
[Riffle] ZRANGE riffle:abc123:ids 0 19
[Riffle] FETCH cursor_id=abc123 offset=0 limit=20 fetched=20
```

**Memory store output example:**
```
[Riffle::Memory] STORE cursor_id=abc123 ids_count=1000 total_count=1000 ttl=1800s
[Riffle::Memory] EXISTS cursor_id=abc123 result=true
[Riffle::Memory] FETCH cursor_id=abc123 offset=0 limit=20 fetched=20
```

## Usage

### With Kaminari

Use the `riffle` macro in your controller:

```ruby
class UsersController < ApplicationController
  # Enable Riffle for specified actions
  riffle only: [:index]

  def index
    @users = User.order(:name).page(params[:page]).per(20)
  end
end
```

Views work as usual:

```erb
<%= paginate @users %>
```

The `cursor_id` parameter is automatically included in pagination links.

### With Pagy

Use the `pagy_riffle` method in your controller:

```ruby
class UsersController < ApplicationController
  include Pagy::Backend

  def index
    @pagy, @users = pagy_riffle(User.order(:name))
  end
end
```

Views work as usual:

```erb
<%== pagy_nav(@pagy) %>
```

### View Helpers

#### Get cursor_id

```erb
<%= riffle_cursor_id(@users) %>
```

#### Hidden field for forms

```erb
<%= form_with url: users_path do |f| %>
  <%= riffle_cursor_field(@users) %>
  <!-- form content -->
<% end %>
```

#### Generate path with cursor_id

```erb
<%= riffle_path(users_path, @users, page: 2) %>
```

## Handling Deleted Records

When records are deleted during pagination, Riffle automatically handles it:

1. Fetch records by cached IDs
2. Detect deleted records
3. Remove deleted IDs from cache
4. Backfill with next available IDs
5. Update `total_count`

This ensures the page size is maintained even when deletions occur.

```
# Log output example
[Riffle::Memory] FETCH cursor_id=xxx offset=20 limit=10 fetched=10
[Riffle::Memory] REMOVE_IDS cursor_id=xxx ids=[42, 57]
[Riffle::Memory] DECR_COUNT cursor_id=xxx by=2 new_total=198
[Riffle::Memory] FETCH cursor_id=xxx offset=30 limit=2 fetched=2
```

## API/JSON Responses

Riffle works with existing Kaminari/Pagy serialization. Simply include the `cursor_id` in your response.

```ruby
# Controller
def index
  @users = User.order(:name).page(params[:page]).per(20)

  render json: {
    users: @users.as_json,
    meta: {
      current_page: @users.current_page,
      total_pages: @users.total_pages,
      total_count: @users.total_count,
      cursor_id: @users.riffle_cursor_id
    }
  }
end
```

The frontend sends `?cursor_id=xxx&page=2` for subsequent requests.

## Architecture

### Redis Operations

| Operation | Command | Complexity |
|-----------|---------|------------|
| Store IDs | ZADD (score=index) | O(log N) |
| Get page | ZRANGE start end | O(log N + M) |
| Total count | ZCARD | O(1) |
| Set TTL | EXPIRE | O(1) |

### Redis Cluster

Riffle uses two Redis keys per cursor (`riffle:{CURSOR_ID}:ids` and
`riffle:{CURSOR_ID}:meta`) and updates them inside `MULTI` blocks. The
`{CURSOR_ID}` hash tag ensures both keys hash to the same Cluster slot,
so MULTI does not raise CROSSSLOT.

### Instrumentation

Riffle emits `ActiveSupport::Notifications` events so you can wire it
into your APM, StatsD, or logger of choice without monkey-patching.

| Event | Fired when | Payload |
|---|---|---|
| `cursor_created.riffle` | `Cursor.create` materializes a new snapshot | `cursor_id`, `total_count`, `requested_ids_count` |
| `page_fetched.riffle` | `PageFetcher#fetch` returns a page | `cursor_id`, `page`, `per_page`, `fetched_count`, `total_count`, `truncated` |
| `backfill_triggered.riffle` | A page lookup detects rows deleted from the DB and the cache compensates | `cursor_id`, `deleted_ids_count`, `removed_count` |

Subscribe with the standard ActiveSupport API:

```ruby
ActiveSupport::Notifications.subscribe(/\.riffle\z/) do |*args|
  event = ActiveSupport::Notifications::Event.new(*args)
  StatsD.timing("riffle.#{event.name.split('.').first}", event.duration)
end
```

### Operational Considerations

Riffle treats Redis as a hard dependency, not an optional cache. A
Redis outage will surface as exceptions on paginated endpoints — the
gem does not silently fall back to a database OFFSET path, because
that would break the snapshot semantics it promises.

Recommended operational setup:

- Run Redis in a high-availability configuration (Sentinel or Cluster)
- Add a circuit breaker around `pagy_riffle` / `User.page` if you need
  page rendering to degrade gracefully under a Redis outage
- Monitor Redis connection health and the truncation / cursor-expiration
  WARN logs to catch capacity issues early
- Consider isolating Riffle to a dedicated Redis logical DB if you
  share a Redis instance with Sidekiq or other workloads, so that
  eviction policies cannot evict cursors mid-pagination

### Core API

You can use the Core API directly:

```ruby
# Create cursor (use the model's primary_key, not :id, to support UUIDs)
base_scope = User.includes(:profile).order(:name)
ids = base_scope.pluck(User.primary_key)
cursor = Riffle::Core::Cursor.create(ids, total_count: ids.size)

# Find cursor
cursor = Riffle::Core::Cursor.find(cursor_id)

# Fetch page from snapshot. Pass the relation (preferred) so includes /
# joins / select are preserved when fetching the actual records.
snapshot = Riffle::Core::Snapshot.new(cursor)
fetcher = Riffle::Core::PageFetcher.new(snapshot: snapshot, relation: base_scope)
result = fetcher.fetch(page: 2, per_page: 20)

result.records      # => [User, User, ...]
result.total_count  # => 1000
result.cursor_id    # => "abc123xyz"
result.total_pages  # => 50
```

## Security

### About cursor_id

- `cursor_id` is a 128-bit random string, making it practically impossible to guess
- Since it's exposed as a URL parameter, it may leak to external sites via referrer headers
- `cursor_id` only reveals a list of record IDs, not actual data

### Authorization

Riffle does not perform authorization checks. Authorization is the application's responsibility.

```ruby
# Example: Apply authorization scope before pagination
@users = current_user.visible_users.order(:name).page(params[:page])
```

Only IDs from this scoped query are cached, so only authorized records are included.

### For Sensitive Data

- Consider using a shorter TTL
- Disable logging if necessary

```ruby
Riffle.configure do |config|
  config.ttl = 5 * 60  # 5 minutes
  config.logger = nil  # Disable logging
end
```

## Testing

Use the in-memory store for testing:

```ruby
# spec/spec_helper.rb or test/test_helper.rb
Riffle.store = Riffle::Store::Memory.new

RSpec.configure do |config|
  config.before(:each) do
    Riffle.store.clear
  end
end
```

## Development

```bash
$ bin/setup        # Install dependencies
$ bundle exec rspec # Run tests
$ bin/console      # Interactive console
```

## License

MIT License

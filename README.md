# Riffle

Riffle is a cursor-based caching gem for pagination. It is designed for use with Redis and optimized for Redis Sorted Set operations, eliminating repetitive `COUNT(*)` and `LIMIT/OFFSET` queries. An in-memory store is also available for testing without Redis.

Supports both Kaminari and Pagy.

[日本語ドキュメント](README_ja.md)

## How It Works

```
┌─────────────────────────────────────┐
│  kaminari adapter / pagy adapter    │  ← Adapter layer
├─────────────────────────────────────┤
│         riffle (core)             │  ← Core API layer
├─────────────────────────────────────┤
│         Redis Sorted Set            │  ← Storage layer
└─────────────────────────────────────┘
```

1. On the first request, fetch all record IDs and cache them in Redis
2. For subsequent pages, retrieve IDs from cache and fetch records by those IDs
3. Include cursor ID in pagination links to maintain snapshot consistency

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

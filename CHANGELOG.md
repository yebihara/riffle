# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]
### Changed (breaking)
- **Kaminari adapter redesigned around `ActiveRecord::Relation#extending`; the old global patches are gone** ([#7](https://github.com/yebihara/riffle/issues/7)). Removed the `riffle only:` controller macro, the request-global `Riffle::Current`, the every-model `.page` aliasing (`hooks.rb`), and the every-relation `RelationExtension` prepend. Riffle is now opt-in per model and per call site:
  - `include Riffle::Model` on a model (usually `ApplicationRecord`) adds a `.riffle(cursor:, param:, store:)` scope. Chain it **after** `.page`/`.per` — it must come after `.page` so its cursor-backed `total_count` wins over Kaminari's (Kaminari mixes `total_count` in at `.page` time, and Ruby resolves the later-added module first). Applying `.riffle` before `.page` raises `Riffle::ConfigurationError` at the `.page` call itself; `.per` / `.page` after `.riffle` are fine, and relations derived from a loaded riffle relation re-query against the same snapshot instead of returning the parent's memoized page.
  - `riffle_page(relation, per:, page:, param:, store:)` controller helper replaces the macro, reading the page and cursor params from the request (symmetric with `pagy_riffle`).
  - Each `.riffle` produces an independent snapshot with its own `param:` (default `Riffle.config.cursor_param`), **fixing the request-global cursor corruption** that let two paginated collections in one action clobber each other's snapshots. View helpers (`paginate`, `riffle_cursor_field`, `riffle_path`) now read the relation's own `riffle_cursor_param`.
  - Works outside controllers (jobs, service objects) — no `params`/request required; pass `cursor:` directly, and it works without Kaminari installed (a missing page size then raises a descriptive `Riffle::ConfigurationError` — chain `.limit(n)`). `other.merge(riffled_scope)` is unsupported (instance variables do not transfer through `merge`).

### Added
- Standalone pagination without Kaminari or Pagy ([#8](https://github.com/yebihara/riffle/issues/8)): `.riffle(page:, per:)` states the page and size directly (request-param strings accepted, `page` clamped to >= 1; the keywords win over chained `.page`/`.per` when both are present), and `riffle_meta` returns the pager metadata a JSON client needs (`cursor_id`, `page`, `per_page`, `total_count`, `total_pages`, `next_page`, `prev_page`).
- GitHub Actions CI: runs the suite on Pagy 8, 9, and 43 with a real Redis service container ([#2](https://github.com/yebihara/riffle/issues/2)). The Redis store spec now honors `REDIS_URL` to run against a real server instead of mock_redis.
- Pagy 9 support: the adapter now detects the installed Pagy major and uses `:limit` (Pagy 9) or `:items` (Pagy 8) for the page-size var, request param, and `Pagy.new` keyword ([#1](https://github.com/yebihara/riffle/issues/1)).
- Pagy 43 support: a dedicated adapter (`backend_v43.rb` / `frontend_v43.rb`) built on the rewritten API — `Pagy::Offset` + `Pagy::Request` instead of `Pagy::Backend`, and the `:querify` option instead of the removed `pagy_url_for` to carry `cursor_id` into page links. `pagy_riffle` accepts both the keyword (`pagy_riffle(collection, **options)`) and trailing-positional-Hash (`pagy_riffle(collection, vars)`) calling styles ([#5](https://github.com/yebihara/riffle/issues/5)). Pagy 43 requires Ruby >= 3.3. Limit handling matches the 8/9 adapter: the `?limit=` request param is honored (and carried into page links, since Pagy 43 drops it otherwise), clamped by `:max_limit`, and takes precedence over a global `Pagy::OPTIONS[:limit]`. cursor_id/page/limit are read from the controller `#params` first (so JSON-body params and Symbol keys work), falling back to the Pagy request, and an explicit `request:` option takes precedence over the controller's `#params`; callers exposing only `#params` (jobs, service objects) work without a `#request`. Param resolution matches native Pagy: `?page=0` / non-numeric pages clamp to page 1, and `:root_key` (JSON:API) nesting is honored for page/limit, including in generated page links. Requiring the adapter files before pagy defers implementation selection to the first `pagy_riffle` call (warning on unsupported majors) instead of silently binding one.
- `Riffle::Adapters::Pagy.supported?` / `.limit_var` / `.v43?` version shim. Unsupported Pagy majors (7 and below, 10–42, 44 and above) log a warning and skip Pagy adapter setup instead of failing at runtime.
- `gemfiles/pagy_8.gemfile`, `gemfiles/pagy_9.gemfile`, and `gemfiles/pagy_43.gemfile` for running the suite against each supported Pagy major.
- Configurable Redis key prefix via `Configuration#redis_key_prefix` (default `"riffle"`) and `Store::Redis.new(key_prefix: ...)` per-instance override.
- `PageFetcher.new(relation:)` keyword to preserve `includes` / `joins` / `select` / additional `where` clauses across page navigation. `model_class:` continues to work for the legacy no-scope path.
- `Configuration#on_max_ids_exceeded` (`:truncate` default, `:raise` opt-in) plus a `truncated` flag persisted alongside the cursor and exposed via `Store::Base#truncated?` and `PageFetcher::Result#truncated?`.
- `Riffle::MaxIdsExceeded` error type (raised when `:raise` mode trips).
- `Store::Base#remove_ids_and_decrement` — atomic-by-pair backfill removal that decrements counts by the actual ZREM count, guarding against concurrent double-decrement.
- Test infrastructure: spec/support/active_record.rb, spec/support/kaminari.rb, mock_redis-backed Redis store specs, full Pagy and Kaminari adapter specs.

### Changed
- **Renamed gem from `chikuden` to `riffle`** (module / namespace / file paths / Redis key prefix / log prefix all updated).
- Redis keys now use a `{cursor_id}` hash tag (`riffle:{CURSOR_ID}:ids` and `riffle:{CURSOR_ID}:meta`) so MULTI blocks succeed on Redis Cluster.
- `Store::Redis#fetch_page` no longer coerces results with `.to_i`. UUID / string-typed primary keys are returned as-is so ActiveRecord can cast them at WHERE-clause time.
- `PageFetcher` and the adapters now use `model_class.primary_key` / `klass.primary_key` instead of hardcoded `:id`.
- `PageFetcher#fetch` and `Snapshot#total_pages` now raise `ArgumentError` for non-positive `per_page` (was `FloatDomainError` via `Float::INFINITY.ceil`).
- `Store::Memory#store` now de-duplicates IDs to match Redis Sorted Set unique-member semantics; existing tests that intentionally passed duplicate IDs continue to pass.
- `Store::Memory#decrement_total_count` now also decrements `stored_count` (it previously only adjusted `total_count`, contradicting the Redis store contract).
- Bumped minimum Ruby to 3.1 and minimum Rails (railties / activesupport) to 7.0; older versions are EOL.
- README and gemspec reframed around the concrete guarantee — no skipped or duplicated rows while paging — instead of the "application-level Repeatable Read" analogy. A new "Precise Semantics" section documents what is and is not frozen, including revisit-after-shrinkage behavior and the derived-relation caveat.

### Fixed
- **UUID / custom string primary keys are no longer corrupted** on the Redis store path (issue #001).
- **Original relation scope** (`includes`, `select`, `joins`, additional `where`) is preserved across page navigation; previous behavior issued the per-page WHERE against the bare model class, dropping all scope and causing N+1 (issue #002).
- Redis Cluster compatibility: MULTI blocks no longer trip CROSSSLOT (issue #003).
- max_ids truncation is no longer silent — emits a WARN log and surfaces via `Result#truncated?` (issue #004).
- `per_page=0` (and other non-positive values) raise `ArgumentError` cleanly instead of crashing with `FloatDomainError` (issue #005).
- Backfill `total_count` no longer double-decrements under concurrent requests, and the count update is atomic-by-pair (issues #008 + #009).

### Removed
- Dead code: `lib/riffle/adapters/kaminari/railtie.rb` (never required), `Riffle::CursorNotFound` (defined but never raised), `Riffle::Current.per` (defined but never used) (issue #013).

## [0.1.0] - 2026-02-07

### Added
- Initial release as `chikuden`.
- Redis Sorted Set based ID caching with snapshot semantics across page navigation.
- Kaminari adapter (controller macro, relation extension, view helpers).
- Pagy adapter (backend, frontend).
- In-memory store for testing.
- Backfill mechanism for records deleted between snapshot creation and page fetch.

[Unreleased]: https://github.com/yebihara/riffle/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/yebihara/riffle/releases/tag/v0.1.0
